#!/bin/bash
# fetch_build_remote.sh — copy TRILLIUM + BIN tarballs onto CN servers and extract there
set -euo pipefail

# -------- Inputs (same names you already use) --------
NEW_VERSION="${NEW_VERSION:?NEW_VERSION is required}"          # e.g., 6.3.0_EA2
NEW_BUILD_PATH="${NEW_BUILD_PATH:?NEW_BUILD_PATH is required}"  # e.g., /home/labadmin or /home/labadmin/6.3.0[/EAx]
SERVER_FILE="${SERVER_FILE:-server_pci_map.txt}"               # list of CN servers (first column host/IP)

# Build source (where tarballs live)
BUILD_SRC_HOST="${BUILD_SRC_HOST:?BUILD_SRC_HOST is required}"
BUILD_SRC_USER="${BUILD_SRC_USER:-labadmin}"
BUILD_SRC_BASE="${BUILD_SRC_BASE:-/repo/builds}"
BUILD_SRC_PASS="${BUILD_SRC_PASS:-}"                           # if set → sshpass for build source
BUILD_SRC_KEY="${BUILD_SRC_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"

# CN server SSH
CN_USER="${CN_USER:-labadmin}"                                 # user on CN servers
CN_PASS="${CN_PASS:-}"                                         # if set → sshpass for CN
CN_KEY="${CN_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"

EXTRACT_BUILD_TARBALLS="${EXTRACT_BUILD_TARBALLS:-true}"

# -------- Derive names --------
BASE_VER="$(printf '%s' "$NEW_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
TAG=""
if [[ "$NEW_VERSION" == *_* ]]; then TAG="${NEW_VERSION##*_}"; fi
TRIL_FILE="TRILLIUM_5GCN_CNF_REL_${BASE_VER}.tar.gz"
BIN_GLOB="*BIN_REL_${BASE_VER}.tar.gz"

# -------- Normalize NEW_BUILD_PATH like .../6.3.0_EA2 -> .../6.3.0/EA2 --------
if [[ -n "$TAG" ]] && [[ "$NEW_BUILD_PATH" == *"/${BASE_VER}_${TAG}"* ]]; then
  NEW_BUILD_PATH="$(printf '%s' "$NEW_BUILD_PATH" | sed -E "s#/${BASE_VER}_${TAG}(\/|$)#/${BASE_VER}/${TAG}\1#")"
fi

# -------- Compute DEST_DIR on CN server --------
DEST_DIR="$NEW_BUILD_PATH"
case "$DEST_DIR" in
  *"/${BASE_VER}/"*|*"/${BASE_VER}") : ;;
  *)
    if [[ -n "$TAG" ]]; then DEST_DIR="${DEST_DIR%/}/${BASE_VER}/${TAG}"
    else                       DEST_DIR="${DEST_DIR%/}/${BASE_VER}"
    fi
    ;;
esac
if [[ -n "$TAG" && "$DEST_DIR" == */"${BASE_VER}" ]]; then
  DEST_DIR="${DEST_DIR}/${TAG}"
fi

# -------- Auth helpers --------
ssh_opts=(-o StrictHostKeyChecking=no)
b_ssh=() ; b_scp=()
if [[ -n "$BUILD_SRC_PASS" ]]; then
  command -v sshpass >/dev/null 2>&1 || { echo "❌ sshpass missing on Jenkins"; exit 2; }
  b_ssh=(sshpass -p "$BUILD_SRC_PASS" ssh "${ssh_opts[@]}")
  b_scp=(sshpass -p "$BUILD_SRC_PASS" scp "${ssh_opts[@]}")
else
  [[ -f "$BUILD_SRC_KEY" ]] || { echo "❌ Build source key not found: $BUILD_SRC_KEY"; exit 2; }
  b_ssh=(ssh -i "$BUILD_SRC_KEY" "${ssh_opts[@]}")
  b_scp=(scp -i "$BUILD_SRC_KEY" "${ssh_opts[@]}")
fi
c_ssh=() ; c_scp=()
if [[ -n "$CN_PASS" ]]; then
  command -v sshpass >/dev/null 2>&1 || { echo "❌ sshpass missing on Jenkins"; exit 2; }
  c_ssh=(sshpass -p "$CN_PASS" ssh "${ssh_opts[@]}")
  c_scp=(sshpass -p "$CN_PASS" scp "${ssh_opts[@]}")
else
  [[ -f "$CN_KEY" ]] || { echo "❌ CN key not found: $CN_KEY"; exit 2; }
  c_ssh=(ssh -i "$CN_KEY" "${ssh_opts[@]}")
  c_scp=(scp -i "$CN_KEY" "${ssh_opts[@]}")
fi

REMOTE_BUILD="${BUILD_SRC_USER}@${BUILD_SRC_HOST}"

# -------- Find remote source directory containing TRILLIUM --------
ROOT="${BUILD_SRC_BASE%/}"
SEARCH_DIRS=("$ROOT" "$ROOT/${BASE_VER}" "$ROOT/${NEW_VERSION}")

FOUND_DIR=""
for cand in "${SEARCH_DIRS[@]}"; do
  if "${b_ssh[@]}" "$REMOTE_BUILD" "test -s '$cand/$TRIL_FILE'"; then
    FOUND_DIR="$cand"; break
  fi
done
if [[ -z "$FOUND_DIR" ]]; then
  echo "❌ $TRIL_FILE not found under:"
  printf '   - %s\n' "${SEARCH_DIRS[@]}"
  exit 3
fi
echo "✅ Build source dir: $FOUND_DIR"

# -------- List BINs (optional) --------
readarray -t BIN_LIST < <( "${b_ssh[@]}" "$REMOTE_BUILD" "ls -1 '$FOUND_DIR'/$BIN_GLOB 2>/dev/null || true" )
echo "ℹ️  BIN files found: ${#BIN_LIST[@]}"

# -------- Helper: copy file to CN using scp -3 if possible; else 2-step --------
copy_to_cn() {
  local src_file="$1"  # absolute path on build source
  local cn_host="$2"
  local dest_dir="$3"

  # Try scp -3 (third-party copy through Jenkins, no disk)
  if scp -h 2>&1 | grep -q -- ' -3'; then
    # Build scp command with auth for both sides
    # Note: sshpass cannot drive two endpoints at once. For mixed password/key envs, -3 may not work.
    if [[ -z "$BUILD_SRC_PASS" && -z "$CN_PASS" ]]; then
      scp -3 -i "$BUILD_SRC_KEY" -o StrictHostKeyChecking=no \
          -i "$CN_KEY" \
          "${REMOTE_BUILD}:${src_file}" "${CN_USER}@${cn_host}:${dest_dir}/"
      return $?
    fi
  fi

  # Fallback: two-step (download to tmp, then push)
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  echo "↪️  Fallback two-step via Jenkins tmp for $(basename "$src_file")"
  "${b_scp[@]}" "${REMOTE_BUILD}:${src_file}" "${tmpdir}/"
  "${c_scp[@]}" "${tmpdir}/$(basename "$src_file")" "${CN_USER}@${cn_host}:${dest_dir}/"
}

# -------- Iterate CN servers and perform remote ops --------
if [[ ! -f "$SERVER_FILE" ]]; then
  echo "❌ SERVER_FILE not found: $SERVER_FILE"; exit 5
fi

while read -r host rest; do
  # skip blanks/comments
  [[ -z "${host// }" ]] && continue
  [[ "$host" =~ ^# ]] && continue

  echo ""
  echo "🧩 Target CN: $host"
  echo "📁 Dest dir : $DEST_DIR"

  # 1) Ensure dest dir on CN
  "${c_ssh[@]}" "${CN_USER}@${host}" "mkdir -p '$DEST_DIR'"

  # 2) Copy TRILLIUM
  copy_to_cn "${FOUND_DIR}/${TRIL_FILE}" "$host" "$DEST_DIR"

  # 3) Copy BINs
  if (( ${#BIN_LIST[@]} > 0 )); then
    for full in "${BIN_LIST[@]}"; do
      base="$(basename "$full")"
      echo "📥 Copying BIN: $base -> $host:$DEST_DIR"
      copy_to_cn "$full" "$host" "$DEST_DIR"
    done
  else
    echo "⚠️  No BINs matching $BIN_GLOB in $FOUND_DIR"
  fi

  # 4) Extract on CN (optional)
  shopt -s nocasematch
  if [[ "$EXTRACT_BUILD_TARBALLS" =~ ^(true|yes|1)$ ]]; then
    echo "📦 Extracting on $host ..."
    # Skip if looks already extracted
    if "${c_ssh[@]}" "${CN_USER}@${host}" "test -d '$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE_VER}'"; then
      echo "ℹ️  TRILLIUM seems extracted already; skipping."
    else
      "${c_ssh[@]}" "${CN_USER}@${host}" "tar -C '$DEST_DIR' -xzf '$DEST_DIR/$TRIL_FILE'"
    fi
    # BINs
    if (( ${#BIN_LIST[@]} > 0 )); then
      for full in "${BIN_LIST[@]}"; do
        base="$(basename "$full")"
        base_dir="${base%.tar.gz}"
        if "${c_ssh[@]}" "${CN_USER}@${host}" "test -d '$DEST_DIR/$base_dir'"; then
          echo "ℹ️  $base appears extracted; skipping."
        else
          "${c_ssh[@]}" "${CN_USER}@${host}" "tar -C '$DEST_DIR' -xzf '$DEST_DIR/$base'"
        fi
      done
    fi
  else
    echo "ℹ️  Extraction disabled."
  fi
  shopt -u nocasematch

  echo "✅ Done for $host → $DEST_DIR"
done < "$SERVER_FILE"

echo ""
echo "🎉 All CN servers processed successfully."
