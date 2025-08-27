#!/usr/bin/env bash
# scripts/.ems_stage.sh
# EMS install + health check + GUI probe (remote via SSH)
# Exits non-zero on any failure so Jenkins aborts.

set -euo pipefail

# ---------- Inputs ----------
: "${NEW_BUILD_PATH:?missing NEW_BUILD_PATH}"          # e.g. /home/labadmin
: "${NEW_VERSION:?missing NEW_VERSION}"                # e.g. 6.3.0_EA3
INSTALL_SERVER_FILE="${INSTALL_SERVER_FILE:-server_pci_map.txt}"
NODE_NAME="${NODE_NAME:-}"                             # optional: match column 1
SSH_KEY="${SSH_KEY:?missing SSH_KEY}"                  # e.g. /var/lib/jenkins/.ssh/jenkins_key
SSH_USER="${SSH_USER:-root}"

# Proxy passthrough (if set on controller)
HP="${http_proxy:-}";   HPS="${https_proxy:-}";   NP="${no_proxy:-}"
HPU="${HTTP_PROXY:-}"; HPSU="${HTTPS_PROXY:-}"; NPU="${NO_PROXY:-}"

# ---------- Helpers ----------
die(){ echo "ERROR: $*" 1>&2; exit 1; }
req(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

req awk; req grep; req sed; req ssh; req curl

SSH_OPTS="-i ${SSH_KEY} -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
rsh(){ ssh $SSH_OPTS "${SSH_USER}@${SERVER_IP}" -- "$@"; }

get_server_ip(){
  local file="$1" name="$2"
  [ -s "$file" ] || die "Server map not found or empty: $file"
  local line ip
  if [ -n "$name" ]; then
    line="$(awk -F: -v n="$name" 'BEGIN{IGNORECASE=1} $0!~/^[[:space:]]*#/ && NF>=2 && $1==n {print; exit}' "$file")" || true
    [ -n "$line" ] || die "No entry for NODE_NAME=\"${name}\" in $file"
  else
    line="$(awk -F: '$0!~/^[[:space:]]*#/ && NF>=2 {print; exit}' "$file")"
  fi
  ip="$(printf '%s\n' "$line" | awk -F: '{print $2}')"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid IP parsed from: $line"
  printf "%s" "$ip"
}

ssh_preflight_retry(){
  local attempts=0
  until rsh true; do
    attempts=$((attempts+1))
    [ $attempts -ge 3 ] && return 1
    echo "…SSH preflight failed (try $attempts), retrying in 3s…"
    sleep 3
  done
  return 0
}

# ---------- Resolve target & SSH preflight ----------
SERVER_IP="$(get_server_ip "$INSTALL_SERVER_FILE" "$NODE_NAME")"
echo ">>> Target server: ${SERVER_IP}"
ssh_preflight_retry || die "SSH key login failed for ${SSH_USER}@${SERVER_IP} using ${SSH_KEY}"
echo "OK: SSH key login"

# ---------- Build EMS path ----------
BASE_VER="${NEW_VERSION%%_*}"     # e.g., 6.3.0
TAG="${NEW_VERSION#*_}"           # e.g., EA3
[ "$BASE_VER" != "$NEW_VERSION" ] || die "NEW_VERSION must look like 6.3.0_EA3 (got: $NEW_VERSION)"
EMS_SCRIPTS_DIR="${NEW_BUILD_PATH}/${TAG}/TRILLIUM_5GCN_CNF_REL_${BASE_VER}/nf-services/scripts"
echo "EMS scripts dir (remote): ${EMS_SCRIPTS_DIR}"

# ---------- Remote env bootstrap (profile, PATH, KUBECONFIG, proxies) ----------
# NOTE: Temporarily disable nounset while sourcing profiles (they touch PS1/XDG_*).
REMOTE_ENV="\
export http_proxy='${HP}'; export https_proxy='${HPS}'; export no_proxy='${NP}'; \
export HTTP_PROXY='${HPU}'; export HTTPS_PROXY='${HPSU}'; export NO_PROXY='${NPU}'; \
set +u; \
[ -f /etc/profile ] && . /etc/profile || true; \
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc || true; \
[ -f ~/.bashrc ] && . ~/.bashrc || true; \
: \${PS1:=}; \
: \${XDG_DATA_DIRS:=/usr/local/share:/usr/share}; \
set -u; \
export PATH=\$PATH:/usr/local/bin:/usr/bin:/bin; \
[ -z \"\${KUBECONFIG:-}\" ] && [ -f /root/.kube/config ] && export KUBECONFIG=/root/.kube/config || true; \
true"

# ---------- Run EMS install remotely ----------
rsh "bash -euo pipefail -c '
  ${REMOTE_ENV}
  [ -d \"$EMS_SCRIPTS_DIR\" ] || { echo \"EMS scripts dir not found: $EMS_SCRIPTS_DIR\" 1>&2; exit 1; }
  command -v kubectl >/dev/null 2>&1 || { echo \"kubectl not found on remote host\" 1>&2; exit 1; }
  echo \"kubectl: \$(kubectl version --client --short 2>/dev/null || true)\"
  echo \"context: \$(kubectl config current-context 2>/dev/null || echo none)\"
  cd \"$EMS_SCRIPTS_DIR\"
  chmod +x install_ems.sh
  ./install_ems.sh
'"

# ---------- Remote health check via kubectl ----------
echo "Waiting up to 180s for EMS pods Ready (n/n) & Running…"
rsh "bash -euo pipefail -c '
  ${REMOTE_ENV}
  deadline=\$(( \$(date +%s) + 180 ))
  ems_all_ready() {
    mapfile -t lines < <(kubectl get pods -A 2>/dev/null | grep -i ems || true)
    ((${#lines[@]})) || return 1
    for l in \"\${lines[@]}\"; do
      ready=\$(echo \"\$l\" | awk \"{print \\$3}\")
      status=\$(echo \"\$l\" | awk \"{print \\$4}\")
      case \"\$ready\" in
        */*) r=\"\${ready%/*}\"; t=\"\${ready#*/}\";;
        *)   r=0; t=1;;
      esac
      if [ \"\$r\" != \"\$t\" ] || [ \"\$status\" != \"Running\" ]; then
        return 1
      fi
    done
    return 0
  }
  while :; do
    if ems_all_ready; then
      echo \"EMS pods Ready:\"
      kubectl get pods -A | grep -i ems || true
      break
    else
      echo \"…waiting:\"
      kubectl get pods -A | grep -i ems || echo \"(no ems pods yet)\"
    fi
    [ \"\$(date +%s)\" -lt \"\$deadline\" ] || { echo \"Timeout: EMS pods not Ready within 3 minutes\" 1>&2; exit 1; }
    sleep 5
  done
  echo \"--- short watch ---\"
  for i in 1 2 3; do
    kubectl get pod -A | grep -i ems || true
    sleep 3
  done
'"

# ---------- GUI probe ----------
EMS_URL="https://${SERVER_IP}.nip.io/ems/register"
echo "Probing EMS GUI: $EMS_URL"
code="$(curl -sk -o /dev/null -w '%{http_code}' "$EMS_URL" || true)"
if [ "$code" = "200" ] || [ "$code" = "302" ]; then
  echo "OK: EMS GUI reachable (HTTP $code) at $EMS_URL"
else
  die "EMS GUI not reachable (HTTP $code) at $EMS_URL"
fi

echo "DONE: EMS remote install & checks ok (register once: user=root, name=root, password=root123)"
