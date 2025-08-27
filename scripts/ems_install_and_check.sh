#!/usr/bin/env bash
# scripts/ems_install_and_check.sh
# Fail-fast EMS install + health check + GUI probe
set -euo pipefail

# ---------- config / inputs ----------
: "${NEW_BUILD_PATH:?missing NEW_BUILD_PATH}"
: "${NEW_VERSION:?missing NEW_VERSION}"       # e.g., 6.3.0_EA3
INSTALL_SERVER_FILE="${INSTALL_SERVER_FILE:-server_pci_map.txt}"
NODE_NAME="${NODE_NAME:-}"                     # optional: choose a specific server name (column 1)

# ---------- helpers ----------
die(){ echo "❌ $*"; exit 1; }
req(){ command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

# Extract SERVER_IP from server_pci_map.txt
# Format:
# <name>:<ip>:<build_path>:<VM|SRIOV>:<N3>:<N6>:<N4_CIDR>:<AMF_N2_IP>
get_server_ip(){
  local file="$1" name_filter="$2"
  [ -s "$file" ] || die "Server map not found or empty: $file"

  # Pick the matching line: by NODE_NAME if provided, else first non-comment/non-empty
  local line
  if [ -n "$name_filter" ]; then
    line="$(awk -F: -v n="$name_filter" 'BEGIN{IGNORECASE=1} $0!~/^[[:space:]]*#/ && NF>=2 && $1==n {print; exit}' "$file")"
    [ -n "$line" ] || die "No entry for NODE_NAME='$name_filter' in $file"
  else
    line="$(awk -F: '$0!~/^[[:space:]]*#/ && NF>=2 {print; exit}' "$file")"
  fi

  # Field 2 is IP
  local ip
  ip="$(awk -F: '{print $2}' <<<"$line")"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid IP parsed from: $line"
  printf "%s" "$ip"
}

# Build EMS scripts directory from NEW_VERSION and NEW_BUILD_PATH
ems_scripts_dir(){
  local ver="$1" base tag
  base="${ver%%_*}"               # 6.3.0
  tag="${ver#*_}"                 # EA3   (if no '_', tag==ver; detect below)
  [ "$base" != "$ver" ] || die "NEW_VERSION must look like '6.3.0_EA3' (got '$ver')"
  printf "%s/%s/TRILLIUM_5GCN_CNF_REL_%s/nf-services/scripts" "$NEW_BUILD_PATH" "$tag" "$base"
}

# Check that all ems pods are Ready n/n and Status Running
ems_all_pods_ready(){
  # Return 0 if all ems pods are Ready; 1 otherwise. Also tolerate momentary no pods.
  local lines ready status r t ok=1
  mapfile -t lines < <(kubectl get pods -A 2>/dev/null | grep -i 'ems' || true)
  ((${#lines[@]})) || return 1
  for l in "${lines[@]}"; do
    # columns: NAMESPACE NAME READY STATUS ...
    ready="$(awk '{print $3}' <<<"$l")"
    status="$(awk '{print $4}' <<<"$l")"
    case "$ready" in
      */*) r="${ready%/*}"; t="${ready#*/}";;
      *)   r=0; t=1;;
    esac
    if [ "$r" != "$t" ] || [ "$status" != "Running" ]; then
      ok=0; break
    fi
  done
  [ "$ok" -eq 1 ]
}

# ---------- main ----------
req kubectl
req curl

echo ">>> Resolving SERVER_IP from: ${INSTALL_SERVER_FILE}"
SERVER_IP="$(get_server_ip "$INSTALL_SERVER_FILE" "$NODE_NAME")"
export SERVER_IP
EMS_URL="https://${SERVER_IP}.nip.io/ems/register"
echo ">>> SERVER_IP=$SERVER_IP"
echo ">>> EMS URL: $EMS_URL"

EMS_SCRIPTS_DIR="$(ems_scripts_dir "$NEW_VERSION")"
[ -d "$EMS_SCRIPTS_DIR" ] || die "EMS scripts dir not found: $EMS_SCRIPTS_DIR"
echo ">>> Using EMS scripts dir: $EMS_SCRIPTS_DIR"

echo ">>> Running ./install_ems.sh"
( cd "$EMS_SCRIPTS_DIR" && chmod +x install_ems.sh && ./install_ems.sh )

echo ">>> Waiting for EMS pods to become Ready (timeout: 180s)…"
deadline=$(( $(date +%s) + 180 ))
while :; do
  if ems_all_pods_ready; then
    echo "✅ EMS pods are Ready:"
    kubectl get pods -A | grep -i ems || true
    break
  else
    echo "…EMS not ready yet:"
    kubectl get pods -A | grep -i ems || echo "(no ems pods yet)"
  fi
  [ "$(date +%s)" -lt "$deadline" ] || die "Timeout: EMS pods did not become Ready within 3 minutes"
  sleep 5
done

echo '>>> Short watch (3 snapshots) of "kubectl get pod -A | grep ems"'
for i in 1 2 3; do
  echo "--- snapshot $i ---"
  kubectl get pod -A | grep -i ems || true
  sleep 3
done

echo ">>> Probing EMS GUI: $EMS_URL"
code="$(curl -sk -o /dev/null -w '%{http_code}' "$EMS_URL" || true)"
if [ "$code" = "200" ] || [ "$code" = "302" ]; then
  echo "✅ EMS GUI reachable (HTTP $code) at $EMS_URL"
else
  die "EMS GUI not reachable (HTTP $code) at $EMS_URL"
fi

echo "🎉 EMS install & checks completed."
echo "👉 Register via GUI with:"
echo "    User ID: root"
echo "    Name   : root"
echo "    Password: root123"
