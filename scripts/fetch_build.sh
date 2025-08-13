#!/bin/bash
# fetch_build.sh — copy build tarballs from a remote host to NEW_BUILD_PATH (pre-install)
# Accepts NEW_VERSION possibly with a suffix (e.g., 6.3.0_EA2) and uses base version (6.3.0) for filenames/paths.

set -euo pipefail

NEW_VERSION="${NEW_VERSION:?NEW_VERSION is required}"          # e.g. 6.3.0_EA2 or 6.3.0
NEW_BUILD_PATH="${NEW_BUILD_PATH:?NEW_BUILD_PATH is required}"  # e.g. /home/labadmin

BUILD_SRC_HOST="${BUILD_SRC_HOST:-}"            # if empty → skip fetch
BUILD_SRC_USER="${BUILD_SRC_USER:-labadmin}"
BUILD_SRC_BASE="${BUILD_SRC_BASE:-/repo/builds}"
SSH_KEY="${SSH_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"
EXTRACT_BUILD_TARBALLS="${EXTRACT_BUILD_TARBALLS:-true}"
REQUIRE_BIN_REL="${REQUIRE_BIN_REL:-false}"

# --- Derive base version (strip suffix after x.y.z) ---
BASE_VER="$(printf '%s' "$NEW_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"

# Allow overriding filenames if needed
TRIL_FILE="${TRIL_FILE:-TRILLIUM_5GCN_CNF_REL_${BASE_VER}.tar.gz}"
BIN_FILE="${BIN_FILE:-BIN_REL_${BASE_VER}.tar.gz}"

if [[ -z "$BUILD_SRC_HOST" ]]; then
  echo "ℹ️  BUILD_SRC_HOST not set → skipping remote build fetch."
  exit 0
fi

REMOTE_DIR="${BUILD_SRC_BASE%/}/${BASE_VER}"
SSH_OPTS=(-o StrictHostKeyChecking=no -i "$SSH_KEY")

echo "=== Fetch build ==="
echo "  NEW_VERSION : $NEW_VERSION"
echo "  BASE_VER    : $BASE_VER"
echo "  Remote dir  : ${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${REMOTE_DIR}"
echo "  Dest        : ${NEW_BUILD_PATH}"

# --- Check REQUIRED TRILLIUM tarball -----------------------------------------
if ! ssh "${SSH_OPTS[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" "test -s '${REMOTE_DIR}/${TRIL_FILE}'"; then
  echo "❌ Required ${TRIL_FILE} not found on remote: ${REMOTE_DIR}"
  echo "   Run: ssh -i ${SSH_KEY} ${BUILD_SRC_USER}@${BUILD_SRC_HOST} 'ls -l ${REMOTE_DIR}/'"
  exit 2
fi

# --- Locate OPTIONAL BIN tarball ---------------------------------------------
HAVE_BIN=0
if ssh "${SSH_OPTS[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" "test -s '${REMOTE_DIR}/${BIN_FILE}'"; then
  HAVE_BIN=1
else
  BIN_CAND="$(ssh "${SSH_OPTS[@]}" "${BUILD_SRC_USER}@${BUILD_SRC_HOST}" \
    "ls -1 ${REMOTE_DIR}/BIN*${BASE_VER}*.tar.gz 2>/dev/null | head -n1 || true")"
  if [[ -n "${BIN_CAND}" ]]; then
    BIN_FILE="$(basename "${BIN_CAND}")"
    HAVE_BIN=1
    echo "ℹ️  Discovered BIN tarball: ${BIN_FILE}"
  else
    if [[ "${REQUIRE_BIN_REL,,}" =~ ^(true|yes|1)$ ]]; then
      echo "❌ BIN tarball required but not found (REQUIRE_BIN_REL=true)."
      exit 3
    else
      echo "⚠️  BIN tarball not found. Continuing without BIN."
    fi
  fi
fi

mkdir -p "${NEW_BUILD_PATH}"

# --- Copy files --------------------------------------------------------------
SRC_LIST=("${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${REMOTE_DIR}/${TRIL_FILE}")
[[ "$HAVE_BIN" -eq 1 ]] && SRC_LIST+=("${BUILD_SRC_USER}@${BUILD_SRC_HOST}:${REMOTE_DIR}/${BIN_FILE}")

echo "📥 Copying: ${SRC_LIST[*]}"
scp "${SSH_OPTS[@]}" "${SRC_LIST[@]}" "${NEW_BUILD_PATH}/"

# --- Verify & extract --------------------------------------------------------
[[ -s "${NEW_BUILD_PATH}/${TRIL_FILE}" ]] || { echo "❌ Copy failed: ${TRIL_FILE}"; exit 4; }
if [[ "$HAVE_BIN" -eq 1 && ! -s "${NEW_BUILD_PATH}/${BIN_FILE}" ]]; then
  echo "❌ Copy failed: ${BIN_FILE}"; exit 5
fi

shopt -s nocasematch
if [[ "${EXTRACT_BUILD_TARBALLS}" =~ ^(true|yes|1)$ ]]; then
  echo "📦 Extracting ${TRIL_FILE} ..."
  tar -C "${NEW_BUILD_PATH}" -xzf "${NEW_BUILD_PATH}/${TRIL_FILE}"
  if [[ "$HAVE_BIN" -eq 1 ]]; then
    echo "📦 Extracting ${BIN_FILE} ..."
    tar -C "${NEW_BUILD_PATH}" -xzf "${NEW_BUILD_PATH}/${BIN_FILE}"
  fi
else
  echo "ℹ️  Skipping extraction (EXTRACT_BUILD_TARBALLS=${EXTRACT_BUILD_TARBALLS})."
fi
shopt -u nocasematch

echo "✅ Fetch build done."
