#!/usr/bin/env bash
# scripts/fetch_build.sh
# CN login logic matches cluster_reset.sh: SSH key to root (or CN_USER) using SSH_KEY.
# Always use NEW_BUILD_PATH-derived directory on CN (ignore any per-host override).

set -euo pipefail

# ---- Required inputs (from Jenkins) ----
NEW_VERSION="${NEW_VERSION:?NEW_VERSION is required}"            # e.g. 6.3.0_EA2 or 6.3.0
NEW_BUILD_PATH="${NEW_BUILD_PATH:?NEW_BUILD_PATH is required}"    # e.g. /home/labadmin or /home/labadmin/6.3.0[/EAx]
SERVER_FILE="${SERVER_FILE:-server_pci_map.txt}"

# Build source (where tarballs live)
BUILD_SRC_HOST="${BUILD_SRC_HOST:?BUILD_SRC_HOST is required}"
BUILD_SRC_USER="${BUILD_SRC_USER:-labadmin}"
BUILD_SRC_BASE="${BUILD_SRC_BASE:-/repo/builds}"
BUILD_SRC_PASS="${BUILD_SRC_PASS:-}"                              # if set → sshpass
BUILD_SRC_KEY="${BUILD_SRC_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"

# CN auth (KEY-BASED like cluster_reset.sh)
SSH_KEY="${SSH_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"
CN_USER="${CN_USER:-root}"                                        # cluster_reset uses root; override if needed
CN_PORT="${CN_PORT:-22}"

EXTRACT_BUILD_TARBALLS="${EXTRACT_BUILD_TARBALLS:-true}"

# ---- Version parsing ----
BASE_VER="$(printf '%s' "$NEW_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
TAG=""; if [[ "$NEW_VERSION" == *_* ]]; then TAG="${NEW_VERSION##*_}"; fi

TRIL_FILE="TRILLIUM_5GCN_CNF_REL_${BASE_VER}.tar.gz"
BIN_GLOB="*BIN_REL_${BASE_VER}.tar.gz"

# ---- Normalize NEW_BUILD_PATH (…/6.3.0_EA2 → …/6.3.0/EA2) ----
if [[ -n "$TAG" && "$NEW_BUILD_PATH" == *"/${BASE_VER}_${TAG}"* ]]; then
  NEW_BUILD_PATH="$(printf '%s' "$NEW_BUILD_PATH" | sed -E "s#/${BASE_VER}_${TAG}(\/|$)#/${BASE_VER}/${TAG}\1#")"
fi

# ---- Compute final destination dir on CN (ALWAYS from NEW_BUILD_PATH) ----
DEST_DIR="$NEW_BUILD_PATH"
case "$DEST_DIR" in
  *"/${BASE_VER}/"*|*"/${BASE_VER}") : ;;
  *)
    if [[ -n "$TAG" ]]; then DEST_DIR="${DEST_DIR%/}/${BASE_VER}/${TAG}"
    else                       DEST_DIR="${DEST_DIR%/}/${BASE_VER}"
    fi
    ;;
esac
if [[ -n "$TAG" && "$DEST_DIR" == */"${BASE_VER}" ]]; then DEST_DIR="${DEST_DIR}/${TAG}"; fi

# ---- SSH/SCP helpers ----
# Build-host side: allow password or key
if [[ -n "$BUILD_SRC_PASS" ]]; then
  command -v sshpass >/dev/null 2>&1 || { echo "❌ sshpass required for BUILD_SRC_PASS" >&2; exit 2; }
  b_ssh=(sshpass -p "$BUILD_SRC_PASS" ssh -o StrictHostKeyChecking=no)
  b_scp=(sshpass -p "$BUILD_SRC_PASS" scp -q -o StrictHostKeyChecking=no)
else
  [[ -f "$BUILD_SRC_KEY" ]] || { echo "❌ Build source key not found: $BUILD_SRC_KEY" >&2; exit 2; }
  b_ssh=(ssh -i "$BUILD_SRC_KEY" -o StrictHostKeyChecking=no)
  b_scp=(scp -q -i "$BUILD_SRC_KEY" -o StrictHostKeyChecking=no)
fi
REMOTE_BUILD="${BUILD_SRC_USER}@${BUILD_SRC_HOST}"

# CN side: KEY-BASED, like cluster_reset.sh
[[ -f "$SSH_KEY" ]] || { echo "❌ SSH key not found: $SSH_KEY" >&2; exit 2; }
chmod 600 "$SSH_KEY" || true
c_ssh=(ssh -i "$SSH_KEY" -p "$CN_PORT" -o StrictHostKeyChecking=no)
c_scp=(scp -i "$SSH_KEY" -P "$CN_PORT" -q -o StrictHostKeyChecking=no)

# ---- Locate source dir on build host ----
ROOT="${BUILD_SRC_BASE%/}"
SEARCH_DIRS=("$ROOT" "$ROOT/${BASE_VER}" "$ROOT/${NEW_VERSION}")
FOUND_DIR=""
for cand in "${SEARCH_DIRS[@]}"; do
  if "${b_ssh[@]}" "$REMOTE_BUILD" "test -s '$cand/$TRIL_FILE'"; then FOUND_DIR="$cand"; break; fi
done
[[ -n "$FOUND_DIR" ]] || { echo "❌ $TRIL_FILE not found under: ${SEARCH_DIRS[*]}" >&2; exit 3; }
echo "✅ Build source dir: $FOUND_DIR"

# ---- List BINs ----
readarray -t BIN_LIST < <( "${b_ssh[@]}" "$REMOTE_BUILD" "ls -1 '$FOUND_DIR'/$BIN_GLOB 2>/dev/null || true" )
echo "ℹ️  BIN files found: ${#BIN_LIST[@]}"

# ---- Cache downloads once on Jenkins; upload to each CN ----
TMPDIR="$(mktemp -d)"; trap 'rm -rf "$TMPDIR"' EXIT
download_once() {
  local src="$1" base; base="$(basename "$src")"
  if [[ ! -s "$TMPDIR/$base" ]]; then
    echo "⬇️  Downloading: $base"
    "${b_scp[@]}" "${REMOTE_BUILD}:${src}" "$TMPDIR/"
  fi
}
upload_to_cn() {
  local base="$1" host="$2"
  echo "📥 Uploading: $base -> ${host}:${DEST_DIR}"
  "${c_scp[@]}" "$TMPDIR/$base" "${CN_USER}@${host}:${DEST_DIR}/"
}

# ---- Read servers (ignore extra columns; only use host/IP) ----
[[ -f "$SERVER_FILE" ]] || { echo "❌ SERVER_FILE not found: $SERVER_FILE" >&2; exit 5; }
echo "Targets from ${SERVER_FILE}:"
awk 'NF && $1 !~ /^#/' "$SERVER_FILE" || true

extract_host() {
  local line="$1" host=""
  line="${line%%#*}"; line="$(echo "$line" | xargs)"; [[ -z "$line" ]] && return 1
  # split on colon/space/tab
  # shellcheck disable=SC2206
  local toks=($(echo "$line" | awk -F'[: \t]+' '{for(i=1;i<=NF;i++)print $i}'))
  # pick first IPv4; else first non-path token
  for t in "${toks[@]}"; do [[ "$t" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { host="$t"; break; }; done
  if [[ -z "$host" ]]; then for t in "${toks[@]}"; do [[ "$t" == /* ]] && continue; host="$t"; break; done; fi
  [[ -n "$host" ]] || return 1
  printf '%s' "$host"
}

# ---- Process each CN server ----
while IFS= read -r raw; do
  host="$(extract_host "$raw")" || continue

  echo ""
  echo "🧩 Target CN: $host"
  echo "🔑 CN login : ${CN_USER}@${host} with key ${SSH_KEY}"
  echo "📁 Dest dir : $DEST_DIR"

  # 1) Ensure destination exists on CN (ALWAYS NEW_BUILD_PATH-based)
  "${c_ssh[@]}" "${CN_USER}@${host}" "mkdir -p '$DEST_DIR'"

  # 2) Download from build (once)
  download_once "${FOUND_DIR}/${TRIL_FILE}"
  for full in "${BIN_LIST[@]}"; do download_once "$full"; done

  # 3) Upload to this CN
  upload_to_cn "${TRIL_FILE}" "$host"
  for full in "${BIN_LIST[@]}"; do upload_to_cn "$(basename "$full")" "$host"; done

  # 4) Extract on CN (optional)
  shopt -s nocasematch
  if [[ "$EXTRACT_BUILD_TARBALLS" =~ ^(true|yes|1)$ ]]; then
    echo "📦 Extracting on $host ..."
    # TRILLIUM
    if "${c_ssh[@]}" "${CN_USER}@${host}" "test -d '$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE_VER}'"; then
      echo "ℹ️  TRILLIUM already extracted; skipping."
    else
      "${c_ssh[@]}" "${CN_USER}@${host}" "tar -C '$DEST_DIR' -xzf '$DEST_DIR/$TRIL_FILE'"
    fi
    # BINs
    for full in "${BIN_LIST[@]}"; do
      base="$(basename "$full")"; dir="${base%.tar.gz}"
      if "${c_ssh[@]}" "${CN_USER}@${host}" "test -d '$DEST_DIR/$dir'"; then
        echo "ℹ️  $base already extracted; skipping."
      else
        "${c_ssh[@]}" "${CN_USER}@${host}" "tar -C '$DEST_DIR' -xzf '$DEST_DIR/$base'"
      fi
    done
  else
    echo "ℹ️  Extraction disabled."
  fi
  shopt -u nocasematch

  echo "✅ Done for $host → $DEST_DIR"
done < "$SERVER_FILE"

echo ""
echo "🎉 All CN servers processed successfully."
