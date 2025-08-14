#!/usr/bin/env bash
# Fetch build tarballs from BUILD host → copy directly to CN servers
# - BUILD host: password-based auth via sshpass (BUILD_SRC_PASS)
# - CN servers: key-based auth (CN_SSH_KEY), default user root
# - Destination on CN: derived from NEW_BUILD_PATH + /<BASE>[/<TAG>]
# - No extraction here (EXTRACT_BUILD_TARBALLS is ignored on purpose)

set -euo pipefail

# ---------- helpers ----------
require() { local n="$1" ex="$2"; [[ -n "${!n:-}" ]] || { echo "❌ Missing $n (e.g. $ex)"; exit 2; }; }

base_ver() { printf '%s' "${1%%_*}"; }           # 6.3.0_EA2 -> 6.3.0
ver_tag()  { [[ "$1" == *_* ]] && echo "${1##*_}" || echo ""; }  # 6.3.0_EA2 -> EA2 ; 6.3.0 -> ""

normalize_dest() {  # <root> <BASE> <TAG>
  local root="${1%/}" base="$2" tag="$3"
  case "$root" in
    *"/${base}/"*|*"/${base}")  # already contains BASE (and maybe TAG) → keep
      echo "$root"
      ;;
    *)
      if [[ -n "$tag" ]]; then echo "$root/${base}/${tag}"; else echo "$root/${base}"; fi
      ;;
  esac
}

bool_yes() { shopt -s nocasematch; [[ "${1:-}" =~ ^(1|y|yes|true)$ ]]; local r=$?; shopt -u nocasematch; return $r; }

# ---------- inputs ----------
require NEW_VERSION    "6.3.0_EA2"
require NEW_BUILD_PATH "/home/labadmin"
require SERVER_FILE    "server_pci_map.txt"
require BUILD_SRC_HOST "172.26.2.96"
require BUILD_SRC_USER "labadmin"
require BUILD_SRC_BASE "/CNBuild/6.3.0_EA2"
require CN_SSH_KEY     "/var/lib/jenkins/.ssh/jenkins_key"

# BUILD_SRC_PASS is required for password auth
if [[ -z "${BUILD_SRC_PASS:-}" ]]; then
  echo "❌ BUILD_SRC_PASS is required (password for ${BUILD_SRC_USER}@${BUILD_SRC_HOST})." >&2
  exit 2
fi

[[ -f "$SERVER_FILE" ]] || { echo "❌ $SERVER_FILE not found"; exit 2; }
[[ -f "$CN_SSH_KEY"  ]] || { echo "❌ CN_SSH_KEY not found: $CN_SSH_KEY"; exit 2; }
chmod 600 "$CN_SSH_KEY" || true

BASE="$(base_ver "$NEW_VERSION")"
TAG="$(ver_tag "$NEW_VERSION")"
TRIL_FILE="TRILLIUM_5GCN_CNF_REL_${BASE}.tar.gz"
BIN_GLOB="*BIN_REL_${BASE}.tar.gz"

# ---------- SSH/SCP command templates ----------
# Build host (password via sshpass)
if ! command -v sshpass >/dev/null 2>&1; then
  echo "❌ sshpass is required on the Jenkins agent for BUILD host password auth." >&2
  exit 2
fi
SSH_SRC=(sshpass -p "$BUILD_SRC_PASS" ssh -o StrictHostKeyChecking=no -o BatchMode=no)
# scp -3 will copy via local, we can still use sshpass to feed the source-side password
SCP_3=(sshpass -p "$BUILD_SRC_PASS" scp -3 -o StrictHostKeyChecking=no)

# CN (key-based), default user root unless CN_USER was explicitly set
CN_USER="${CN_USER:-root}"
SSH_CN=(ssh -o StrictHostKeyChecking=no -i "$CN_SSH_KEY")
SCP_CN=(scp -o StrictHostKeyChecking=no -i "$CN_SSH_KEY")

# ---------- sanity/auth checks ----------
echo "Targets from ${SERVER_FILE}:"
awk 'NF && $1 !~ /^#/' "$SERVER_FILE" || true
echo

# Auth precheck to build host
if ! "${SSH_SRC[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" "echo ok" >/dev/null 2>&1; then
  echo "❌ Authentication to build host ${BUILD_SRC_USER}@${BUILD_SRC_HOST} failed (wrong user/pass or password auth disabled)." >&2
  exit 11
fi

# ---------- locate build source dir on build host ----------
ROOT="${BUILD_SRC_BASE%/}"
SEARCH_DIRS=(
  "$ROOT"
  "$ROOT/${BASE}"
  "$ROOT/${NEW_VERSION}"
)

FOUND_DIR=""
for cand in "${SEARCH_DIRS[@]}"; do
  if "${SSH_SRC[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" "test -s '$cand/$TRIL_FILE'"; then
    FOUND_DIR="$cand"
    break
  fi
done

if [[ -z "$FOUND_DIR" ]]; then
  echo "❌ $TRIL_FILE not found under: ${SEARCH_DIRS[*]}" >&2
  exit 3
fi
echo "✅ Build source dir: $FOUND_DIR"

# List BINs on build host
readarray -t BIN_LIST < <(
  "${SSH_SRC[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" "ls -1 '$FOUND_DIR'/$BIN_GLOB 2>/dev/null || true"
)
echo "ℹ️  BIN files found: ${#BIN_LIST[@]}"
echo

# ---------- per-CN host copy ----------
any_failed=0

# We strictly ignore any per-line path and always derive from NEW_BUILD_PATH
while IFS= read -r raw || [[ -n "${raw:-}" ]]; do
  line="$(printf '%s' "${raw:-}" | tr -d '\r')"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

  host_ip=""
  # Accept "name:ip[:whatever]" or bare IP
  if [[ "$line" == *:* ]]; then
    IFS=':' read -r _name ip _maybe <<<"$line"
    host_ip="$(echo -n "${ip:-}" | xargs)"
  else
    host_ip="$(echo -n "$line" | xargs)"
  fi
  [[ -z "$host_ip" ]] && { echo "⚠️  Skipping malformed line: $line"; continue; }

  # Destination dir on CN derived from NEW_BUILD_PATH + BASE[/TAG]
  DEST_DIR="$(normalize_dest "$NEW_BUILD_PATH" "$BASE" "$TAG")"

  echo "🧩 Target CN: $host_ip"
  echo "📁 Dest dir : $DEST_DIR"

  # Create destination dir on CN
  if ! "${SSH_CN[@]}" "${CN_USER}@${host_ip}" "mkdir -p '$DEST_DIR' && chmod 755 '$DEST_DIR'"; then
    echo "❌ Failed to create $DEST_DIR on $host_ip"; any_failed=1; echo; continue
  fi

  # Copy TRILLIUM (remote→remote) via scp -3; fall back to pipe if -3 fails
  copy_ok=0
  if "${SCP_3[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${FOUND_DIR}/${TRIL_FILE}" \
                   "${CN_USER}@${host_ip}:${DEST_DIR}/" >/dev/null 2>&1; then
    copy_ok=1
  else
    # fallback: stream via pipe (more compatible)
    if "${SSH_SRC[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" "cat '$FOUND_DIR/$TRIL_FILE'" \
        | "${SSH_CN[@]}" "${CN_USER}@${host_ip}" "cat > '$DEST_DIR/$TRIL_FILE'"; then
      copy_ok=1
    fi
  fi

  if [[ $copy_ok -ne 1 ]]; then
    echo "❌ Failed to copy $TRIL_FILE to $host_ip:$DEST_DIR"; any_failed=1; echo; continue
  fi

  # Copy BINs (if any) one by one (optional)
  for full in "${BIN_LIST[@]}"; do
    base="$(basename "$full")"
    echo "📥 Copying BIN: $base"
    if ! "${SCP_3[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${full}" \
                       "${CN_USER}@${host_ip}:${DEST_DIR}/" >/dev/null 2>&1; then
      # fallback pipe
      if ! "${SSH_SRC[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" "cat '$full'" \
          | "${SSH_CN[@]}" "${CN_USER}@${host_ip}" "cat > '$DEST_DIR/$base'"; then
        echo "⚠️  Failed to copy BIN: $base to $host_ip (continuing)"
      fi
    fi
  done

  # Verify TRILLIUM on CN
  if ! "${SSH_CN[@]}" "${CN_USER}@${host_ip}" "test -s '$DEST_DIR/$TRIL_FILE'"; then
    echo "❌ Copy verification failed for $TRIL_FILE on $host_ip:$DEST_DIR"; any_failed=1; echo; continue
  fi

  # No extraction here — install stage will handle TRILLIUM untar
  echo "✅ Build files staged on ${host_ip}:${DEST_DIR}"
  echo
done < "$SERVER_FILE"

# ---------- result ----------
if [[ $any_failed -ne 0 ]]; then
  echo "❌ One or more CN targets failed during fetch."
  exit 1
fi
echo "🎉 Fetch stage completed for all CN targets."
