#!/usr/bin/env bash
# scripts/ems_install_and_check.sh
# EMS install + EMS-only health check + GUI probe (remote via SSH)
# Avoids loading remote profiles to prevent PS1/XDG unbound errors.
set -euo pipefail

# ----- Inputs -----
: "${SERVER_FILE:?missing SERVER_FILE}"         # e.g., server_pci_map.txt
: "${SSH_KEY:?missing SSH_KEY}"                 # e.g., /var/lib/jenkins/.ssh/jenkins_key
: "${NEW_BUILD_PATH:?missing NEW_BUILD_PATH}"   # e.g., /home/labadmin/EA3  (NOTE: include the tag folder)
: "${NEW_VERSION:?missing NEW_VERSION}"         # e.g., 6.3.0_EA3
HOST_USER="${HOST_USER:-root}"
HOST_NAME="${HOST_NAME:-}"

# EMS-only readiness knobs
EMS_NAMESPACE="${EMS_NAMESPACE:-}"              # blank = all namespaces
EMS_SELECTOR="${EMS_SELECTOR:-app=ems}"        # label selector; blank -> fallback to name prefix
EMS_NAME_PREFIX="${EMS_NAME_PREFIX:-ems}"      # used if selector yields nothing

# ----- Resolve target from server file -----
pick_line() {
  if [[ -n "${HOST_NAME}" ]]; then
    awk -F: -v n="${HOST_NAME}" '$0!~/^[[:space:]]*#/ && NF>=2 && $1==n {print; exit}' "${SERVER_FILE}"
  else
    awk -F: '$0!~/^[[:space:]]*#/ && NF>=2 {print; exit}' "${SERVER_FILE}"
  fi
}
RAW="$(pick_line || true)"
[[ -n "${RAW}" ]] || { echo "[ems] ERROR: no matching entry in ${SERVER_FILE}"; exit 2; }
TARGET_NAME="$(printf '%s\n' "${RAW}" | awk -F: '{print $1}')"
TARGET_IP="$(printf '%s\n'   "${RAW}" | awk -F: '{print $2}')"
[[ "${TARGET_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "[ems] ERROR: invalid IP in ${RAW}"; exit 2; }
echo "[ems] ▶ target: ${TARGET_NAME} ${TARGET_IP}"

VER="${NEW_VERSION%%_*}"
EMS_DIR="${NEW_BUILD_PATH%/}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"
echo "[ems] EMS_DIR=${EMS_DIR}"

# ----- Remote runner (NO profile sourcing) -----
REMOTE_ENV=$(cat <<'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/bin
[ -z "${KUBECONFIG:-}" ] && [ -f /root/.kube/config ] && export KUBECONFIG=/root/.kube/config || true
true
EOF
)

ssh_run() {
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${TARGET_IP}" \
    bash --noprofile --norc -euo pipefail -c "$1"
}

# ----- Install EMS remotely -----
ssh_run "
${REMOTE_ENV}
[ -d '${EMS_DIR}' ] || { echo '[remote] EMS dir not found: ${EMS_DIR}' 1>&2; exit 3; }
command -v kubectl >/dev/null 2>&1 || { echo '[remote] kubectl not found' 1>&2; exit 3; }
cd '${EMS_DIR}'; chmod +x install_ems.sh; ./install_ems.sh
"

# ----- EMS-only readiness -----
echo "[ems] waiting up to 180s for EMS pods Ready (n/n) & Running…"

K_NS_OPT="-A"; [ -n "${EMS_NAMESPACE}" ] && K_NS_OPT="-n ${EMS_NAMESPACE}"
K_SEL_OPT="";  [ -n "${EMS_SELECTOR}"  ] && K_SEL_OPT="-l ${EMS_SELECTOR}"

ssh_run "
${REMOTE_ENV}
K_NS_OPT='${K_NS_OPT}'; K_SEL_OPT='${K_SEL_OPT}'; NAME_PREFIX='${EMS_NAME_PREFIX}'
deadline=\$(( \$(date +%s) + 180 ))

list_ems() {
  if [ -n \"\$K_SEL_OPT\" ]; then
    kubectl get pods \$K_NS_OPT \$K_SEL_OPT 2>/dev/null | awk 'NR>1{print}'
  else
    kubectl get pods \$K_NS_OPT 2>/dev/null | awk 'NR>1 && tolower(\$0) ~ /'\"${EMS_NAME_PREFIX}\"'/ {print}'
  fi
}

# READY/STATUS fields differ when -A includes NAMESPACE
ready_idx=2; status_idx=3
if echo \"\$K_NS_OPT\" | grep -q '^-A'; then ready_idx=3; status_idx=4; fi

ems_all_ready() {
  mapfile -t L < <(list_ems)
  ((${#L[@]})) || return 1
  for ln in \"\${L[@]}\"; do
    r=\$(echo \"\$ln\" | awk -v i=\$ready_idx '{print \$i}')
    s=\$(echo \"\$ln\" | awk -v i=\$status_idx '{print \$i}')
    case \"\$r\" in */*) have=\"\${r%/*}\"; want=\"\${r#*/}\";; *) have=0; want=1;; esac
    [ \"\$have\" = \"\$want\" ] && [ \"\$s\" = \"Running\" ] || return 1
  done
  return 0
}

while :; do
  if ems_all_ready; then
    echo '[remote] ✅ EMS pods Ready:'
    if [ -n \"\$K_SEL_OPT\" ]; then
      kubectl get pods \$K_NS_OPT \$K_SEL_OPT
    else
      kubectl get pods \$K_NS_OPT | grep -i '\"${EMS_NAME_PREFIX}\"' || true
    fi
    break
  fi
  [ \$(date +%s) -lt \$deadline ] || { echo '[remote] Timeout: EMS not Ready in 180s' 1>&2; exit 4; }
  echo '[remote] …waiting…'; sleep 5
done

echo '[remote] --- short watch ---'
if [ -n \"\$K_SEL_OPT\" ]; then
  for i in 1 2 3; do kubectl get pods \$K_NS_OPT \$K_SEL_OPT; sleep 3; done
else
  for i in 1 2 3; do kubectl get pods \$K_NS_OPT | grep -i '\"${EMS_NAME_PREFIX}\"' || true; sleep 3; done
fi
"

# ----- GUI probe -----
EMS_URL="https://${TARGET_IP}.nip.io/ems/register"
echo "[ems] probing GUI: ${EMS_URL}"
code="$(curl -sk -o /dev/null -w '%{http_code}' "${EMS_URL}" || true)"
if [[ "${code}" == "200" || "${code}" == "302" ]]; then
  echo "[ems] ✅ GUI reachable (HTTP ${code}) at ${EMS_URL}"
else
  echo "[ems] ERROR: GUI not reachable (HTTP ${code}) at ${EMS_URL}"
  exit 5
fi

echo "[ems] 🎉 done. Register via GUI once: user=root, name=root, password=root123"
