#!/usr/bin/env bash
set -euo pipefail

: "${SERVER_FILE:?missing}"
: "${SSH_KEY:?missing}"
: "${INSTALL_IP_ADDR:?missing}"        # e.g. 10.10.10.20/24
: "${CN_BOOTSTRAP_PASS:=root123}"      # Jenkins parameter or env

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=8"
SCRIPT_LOCAL="scripts/bootstrap_keys.sh"
SCRIPT_REMOTE="/root/bootstrap_keys.sh"

# IP-only from CIDR
ALIAS_IP="${INSTALL_IP_ADDR%%/*}"

# Compute local checksum once
LOCAL_SHA="$(sha256sum "${SCRIPT_LOCAL}" | awk '{print $1}')"

# Parse hosts (supports "name:ip:..." or "ip")
mapfile -t HOSTS < <(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){n=split($0,a,":"); print a[2]} else {print $1} }' "${SERVER_FILE}")

ship_and_run() {
  local HOST="$1"

  echo ""
  echo "─── Ship bootstrap_keys.sh to ${HOST} ─────────────────────────────"

  # Try key-based SSH; if it fails, fall back to sshpass (password from CN_BOOTSTRAP_PASS)
  if ! ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" true 2>/dev/null; then
    echo "[ship] Key-based SSH to ${HOST} not ready → using sshpass for initial copy"
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "[ship] Installing sshpass on runner (no upgrades)..."
      sudo -E apt-get install -yq --no-install-recommends --no-upgrade sshpass
    fi
    # Copy via sshpass+scp (password auth) as a fallback
    sshpass -p "${CN_BOOTSTRAP_PASS}" scp -q -o StrictHostKeyChecking=no "${SCRIPT_LOCAL}" "root@${HOST}:${SCRIPT_REMOTE}.tmp"
    sshpass -p "${CN_BOOTSTRAP_PASS}" ssh -o StrictHostKeyChecking=no "root@${HOST}" bash -lc "
      mv -f ${SCRIPT_REMOTE}.tmp ${SCRIPT_REMOTE}
      sed -i 's/\\r\$//' ${SCRIPT_REMOTE} || true
      chmod +x ${SCRIPT_REMOTE}
    "
  else
    # Robust copy via base64 over SSH (preserves bytes)
    base64 -w0 "${SCRIPT_LOCAL}" | ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" "base64 -d > '${SCRIPT_REMOTE}.tmp'"
    ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" bash -lc "
      sed -i 's/\\r\$//' ${SCRIPT_REMOTE}.tmp || true
      mv -f ${SCRIPT_REMOTE}.tmp ${SCRIPT_REMOTE}
      chmod +x ${SCRIPT_REMOTE}
    "
  fi

  # Verify checksum on CN
  REMOTE_SHA="$(ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" sha256sum "${SCRIPT_REMOTE}" 2>/dev/null | awk '{print $1}')"
  if [[ -z "${REMOTE_SHA:-}" || "${REMOTE_SHA}" != "${LOCAL_SHA}" ]]; then
    echo "❌ Checksum mismatch on ${HOST} (local=${LOCAL_SHA} remote=${REMOTE_SHA:-<none>}). Aborting."
    exit 2
  fi
  echo "✅ Script integrity OK on ${HOST}"

  # Run the script ON the CN, targeting host+alias
  echo "[run] ${SCRIPT_REMOTE} --host ${HOST} --alias-ip ${ALIAS_IP} --pass '******' --force"
  ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" \
    "${SCRIPT_REMOTE} --host ${HOST} --alias-ip ${ALIAS_IP} --pass '${CN_BOOTSTRAP_PASS}' --force"
}

for H in "${HOSTS[@]}"; do
  ship_and_run "$H"
done
