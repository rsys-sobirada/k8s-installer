#!/bin/bash
# fetch_build.sh — fetch build tarballs before install
# - NEW_VERSION may have suffix (e.g. 6.3.0_EA2); BASE_VER=6.3.0; TAG=EA2 (if present)
# - Required: TRILLIUM_5GCN_CNF_REL_${BASE_VER}.tar.gz
# - Optional-many: *BIN_REL_${BASE_VER}.tar.gz
# - Remote search order: BUILD_SRC_BASE, BUILD_SRC_BASE/BASE_VER, BUILD_SRC_BASE/NEW_VERSION
# - Destination handling:
#     * If NEW_BUILD_PATH already contains BASE_VER (and maybe TAG), use it as-is.
#     * Else, create NEW_BUILD_PATH/BASE_VER[/TAG] and put files there.
#   → This lets users pass /home/labadmin, /home/labadmin/6.3.0, or /home/labadmin/6.3.0/EA2.

set -euo pipefail

# -------- inputs --------
NEW_VERSION="${NEW_VERSION:?NEW_VERSION is required}"            # e.g. 6.3.0_EA2 or 6.3.0
NEW_BUILD_PATH="${NEW_BUILD_PATH:?NEW_BUILD_PATH is required}"    # e.g. /home/labadmin or /home/labadmin/6.3.0[/EAx]

BUILD_SRC_HOST="${BUILD_SRC_HOST:-}"            # required when using fetch stage
BUILD_SRC_USER="${BUILD_SRC_USER:-labadmin}"
BUILD_SRC_BASE="${BUILD_SRC_BASE:-/repo/builds}"
BUILD_SRC_PASS="${BUILD_SRC_PASS:-}"            # if set → use sshpass
SSH_KEY="${SSH_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"  # used if no password provided

EXTRACT_BUILD_TARBALLS="${EXTRACT_BUILD_TARBALLS:-true}"

# -------- derive names --------
BASE_VER="$(printf '%s' "$NEW_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
TAG=""
if [[ "$NEW_VERSION" == *_* ]]; then TAG="${NEW_VERSION##*_}"; fi

TRIL_FILE="TRILLIUM_5GCN_CNF_REL_${BASE_VER}.tar.gz"
BIN_GLOB="*BIN_REL_${BASE_VER}.tar.gz"

# -------- choose destination dir intelligently --------
# Keep user path as-is if it already includes BASE_VER (and maybe TAG).
DEST_DIR="$NEW_BUILD_PATH"
case "$DEST_DIR" in
  *"/${BASE_VER}/"*|*"/${BASE_VER}") : ;;                                # already has BASE_VER
  *)
    if [[ -n "$TAG" ]]; then DEST_DIR="${DEST_DIR%/}/${BASE_VER}/${TAG}"
    else                       DEST_DIR="${DEST_DIR%/}/${BASE_VER}"
    fi
  ;;
esac
# If user path ends exactly with /BASE_VER and TAG exists but not present, add TAG.
if [[ -n "$TAG" && "$DEST_DIR" == */"${BASE_VER}" ]]; then
  DEST_DIR="${DEST_DIR}/${TAG}"
fi
mkdir -p "$DEST_DIR"

# -------- remote search paths --------
ROOT="${BUILD_SRC_BASE%/}"
SEARCH_DIRS=(
  "$ROOT"
  "$ROOT/${BASE_VER}"
  "$ROOT/${NEW_VERSION}"
)

# -------- choose auth (password first; else key) --------
SSH_BASE_OPTS=(-o StrictHostKeyChecking=no -o BatchMode=yes)
if [[ -n "$BUILD_SRC_PASS" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "❌ sshpass is required on the Jenkins agent for password-based copy." >&2
    exit 2
  fi
  SSH_CMD=(sshpass -p "$BUILD_SRC_PASS" ssh "${SSH_BASE_OPTS[@]}")
  SCP_CMD=(sshpass -p "$BUILD_SRC_PASS" scp "${SSH_BASE_OPTS[@]}")
else
  [[ -f "$SSH_KEY" ]] || { echo "❌ SSH key not found: $SSH_KEY"; exit 2; }
  SSH_CMD=(ssh "${SSH_BASE_OPTS[@]}" -i "$SSH_KEY")
  SCP_CMD=(scp "${SSH_BASE_OPTS[@]}" -i "$SSH_KEY")
fi
REMOTE="${BUILD_SRC_USER}@${BUILD_SRC_HOST}"

if [[ -z "$BUILD_SRC_HOST" ]]; then
  echo "ℹ️  BUILD_SRC_HOST not set → skipping fetch."
  exit 0
fi

echo "=== Fetch build ==="
echo "  NEW_VERSION : $NEW_VERSION"
echo "  BASE_VER    : $BASE_VER"
[[ -n "$TAG" ]] && echo "  TAG         : $TAG"
echo "  Search base : $ROOT"
echo "  Remote user : $BUILD_SRC_USER@$BUILD_SRC_HOST"
echo "  Dest (local): $DEST_DIR"
echo "  Require     : $TRIL_FILE"
echo "  Copy (all)  : $BIN_GLOB"

# -------- find a directory that actually contains TRILLIUM --------
FOUND_DIR=""
for cand in "${SEARCH_DIRS[@]}"; do
  if "${SSH_CMD[@]}" "$REMOTE" "test -s '$cand/$TRIL_FILE'"; then
    FOUND_DIR="$cand"
    break
  fi
done

if [[ -z "$FOUND_DIR" ]]; then
  echo "❌ Could not find $TRIL_FILE in any of:"
  printf '   - %s\n' "${SEARCH_DIRS[@]}"
  echo "Listing contents of each candidate path on remote:"
  for cand in "${SEARCH_DIRS[@]}"; do
    echo "---- $cand"
    "${SSH_CMD[@]}" "$REMOTE" "ls -l '$cand' 2>/dev/null || true" || true
  done
  exit 3
fi

echo "✅ Using remote dir: ${FOUND_DIR}"

# -------- list BINs (optional) --------
readarray -t BIN_LIST < <(
  "${SSH_CMD[@]}" "$REMOTE" "ls -1 '$FOUND_DIR'/$BIN_GLOB 2>/dev/null || true"
)
echo "ℹ️  Found ${#BIN_LIST[@]} BIN file(s)."

# -------- copy files --------
# copy TRILLIUM
"${SCP_CMD[@]}" "${REMOTE}:${FOUND_DIR}/${TRIL_FILE}" "${DEST_DIR}/"

# copy BINs one-by-one (if any)
if (( ${#BIN_LIST[@]} > 0 )); then
  for full in "${BIN_LIST[@]}"; do
    base="$(basename "$full")"
    echo "📥 Copying BIN: $base"
    "${SCP_CMD[@]}" "${REMOTE}:${full}" "${DEST_DIR}/"
  done
else
  echo "⚠️  No BIN files matching ${BIN_GLOB} in ${FOUND_DIR}"
fi

# verify TRILLIUM local copy
[[ -s "${DEST_DIR}/${TRIL_FILE}" ]] || { echo "❌ Copy failed: ${TRIL_FILE}"; exit 4; }

# -------- extract (optional) --------
shopt -s nocasematch
if [[ "$EXTRACT_BUILD_TARBALLS" =~ ^(true|yes|1)$ ]]; then
  echo "📦 Extracting ${TRIL_FILE} into ${DEST_DIR}..."
  tar -C "${DEST_DIR}" -xzf "${DEST_DIR}/${TRIL_FILE}"

  for full in "${BIN_LIST[@]}"; do
    base="$(basename "$full")"
    if [[ -s "${DEST_DIR}/${base}" ]]; then
      echo "📦 Extracting ${base} into ${DEST_DIR}..."
      tar -C "${DEST_DIR}" -xzf "${DEST_DIR}/${base}"
    fi
  done
else
  echo "ℹ️  Skipping extraction (EXTRACT_BUILD_TARBALLS=${EXTRACT_BUILD_TARBALLS})."
fi
shopt -u nocasematch

echo "✅ Fetch build done. Files are in: ${DEST_DIR}"
