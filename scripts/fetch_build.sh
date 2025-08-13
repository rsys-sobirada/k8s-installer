#!/bin/bash
# fetch_build.sh — fetch build tarballs before install
# - NEW_VERSION may have suffix (e.g. 6.3.0_EA2); we use BASE_VER (6.3.0) for paths/files
# - Required: TRILLIUM_5GCN_CNF_REL_${BASE_VER}.tar.gz
# - Optional-many: *BIN_REL_${BASE_VER}.tar.gz (copy ALL matches)

set -euo pipefail

NEW_VERSION="${NEW_VERSION:?NEW_VERSION is required}"          # e.g. 6.3.0_EA2 or 6.3.0
NEW_BUILD_PATH="${NEW_BUILD_PATH:?NEW_BUILD_PATH is required}"  # e.g. /home/labadmin

BUILD_SRC_HOST="${BUILD_SRC_HOST:-}"          # if empty → skip fetch
BUILD_SRC_USER="${BUILD_SRC_USER:-labadmin}"
BUILD_SRC_BASE="${BUILD_SRC_BASE:-/repo/builds}"
SSH_KEY="${SSH_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"
EXTRACT_BUILD_TARBALLS="${EXTRACT_BUILD_TARBALLS:-true}"

# Derive numeric base version (x.y.z)
BASE_VER="$(printf '%s' "$NEW_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"

REMOTE_DIR="${BUILD_SRC_BASE%/}/${BASE_VER}"
TRIL_FILE="TRILLIUM_5GCN_CNF_REL_${BASE_VER}.tar.gz"
BIN_GLOB="*BIN_REL_${BASE_VER}.tar.gz"
SSH_OPTS=(-o StrictHostKeyChecking=no -i "$SSH_KEY")

if [[ -z "$BUILD_SRC_HOST" ]]; then
  echo "ℹ️  BUILD_SRC_HOST not set → skipping remote build fetch."
  exit 0
fi

echo "=== Fetch build ==="
echo "  NEW_VERSION : $NEW_VERSION"
echo "  BASE_VER    : $BASE_VER"
echo "  Remote dir  : ${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${REMOTE_DIR}"
echo "  Dest        : ${NEW_BUILD_PATH}"
echo "  Require     : ${TRIL_FILE}"
echo "  Copy (all)  : ${BIN_GLOB}"

# Verify required TRILLIUM exists
ssh "${SSH_OPTS[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" \
  "test -s '${REMOTE_DIR}/${TRIL_FILE}'" || {
    echo "❌ Missing required ${REMOTE_DIR}/${TRIL_FILE}"
    ssh "${SSH_OPTS[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" "ls -l '${REMOTE_DIR}' || true"
    exit 2
  }

# Discover ALL BIN matches on remote (prefix may vary, suffix fixed)
readarray -t BIN_LIST < <(ssh "${SSH_OPTS[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" \
  "ls -1 ${REMOTE_DIR}/${BIN_GLOB} 2>/dev/null || true")

echo "ℹ️  Found ${#BIN_LIST[@]} BIN file(s)."
mkdir -p "${NEW_BUILD_PATH}"

# Copy TRILLIUM
scp "${SSH_OPTS[@]}" \
  "${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${REMOTE_DIR}/${TRIL_FILE}" \
  "${NEW_BUILD_PATH}/"

# Copy all BIN matches (if any)
if (( ${#BIN_LIST[@]} > 0 )); then
  # Copy one-by-one to avoid local shell globbing issues
  for fullpath in "${BIN_LIST[@]}"; do
    base="$(basename "$fullpath")"
    echo "📥 Copying BIN: ${base}"
    scp "${SSH_OPTS[@]}" \
      "${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${fullpath}" \
      "${NEW_BUILD_PATH}/"
  done
else
  echo "⚠️  No BIN files matching ${BIN_GLOB} — continuing with TRILLIUM only."
fi

# Verify local copy of TRILLIUM
[[ -s "${NEW_BUILD_PATH}/${TRIL_FILE}" ]] || { echo "❌ Copy failed: ${TRIL_FILE}"; exit 3; }

# Extract
shopt -s nocasematch
if [[ "${EXTRACT_BUILD_TARBALLS}" =~ ^(true|yes|1)$ ]]; then
  echo "📦 Extracting ${TRIL_FILE} ..."
  tar -C "${NEW_BUILD_PATH}" -xzf "${NEW_BUILD_PATH}/${TRIL_FILE}"

  # Extract all BINs we copied
  for fullpath in "${BIN_LIST[@]}"; do
    base="$(basename "$fullpath")"
    if [[ -s "${NEW_BUILD_PATH}/${base}" ]]; then
      echo "📦 Extracting ${base} ..."
      tar -C "${NEW_BUILD_PATH}" -xzf "${NEW_BUILD_PATH}/${base}"
    fi
  done
else
  echo "ℹ️  Skipping extraction (EXTRACT_BUILD_TARBALLS=${EXTRACT_BUILD_TARBALLS})."
fi
shopt -u nocasematch

echo "✅ Fetch build done."
