#!/usr/bin/env bash
# scripts/fetch_build.sh
# Thin Bash wrapper that prepares and invokes scripts/fetch_build_remote.sh with Bash.
# It expects all required env vars to be provided by the Jenkins pipeline (NEW_VERSION, NEW_BUILD_PATH, etc).

set -euo pipefail

# --- Locate the worker script ---
WORKER="scripts/fetch_build_remote.sh"
if [[ ! -f "$WORKER" ]]; then
  echo "❌ ${WORKER} not found in $(pwd)" >&2
  exit 1
fi

# --- Normalize line endings / BOM so Bash parses cleanly ---
# Strip CRLF if present
sed -i 's/\r$//' "$WORKER" || true
# Strip UTF-8 BOM if present (try sed hex; fall back to perl if available)
sed -i '1s/^\xEF\xBB\xBF//' "$WORKER" 2>/dev/null || {
  if command -v perl >/dev/null 2>&1; then
    perl -i -pe 'BEGIN{binmode(STDIN);binmode(STDOUT)} s/^\x{FEFF}// if $.==1' "$WORKER" || true
  fi
}

chmod +x "$WORKER"

# --- Optional deps checks (only when using password auth to the build source) ---
if [[ -n "${BUILD_SRC_PASS:-}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "❌ sshpass is required on this agent because BUILD_SRC_PASS is set." >&2
    exit 2
  fi
fi

# --- Friendly log of target servers (if file present) ---
SERVER_LIST="${SERVER_FILE:-server_pci_map.txt}"
if [[ -f "$SERVER_LIST" ]]; then
  echo "Targets from ${SERVER_LIST}:"
  awk 'NF && $1 !~ /^#/' "$SERVER_LIST" || true
else
  echo "ℹ️  SERVER_FILE not found (${SERVER_LIST}); proceeding anyway."
fi

# --- Hand off to the real worker (runs all logic: mkdir/copy/extract on CN hosts) ---
# The worker reads the necessary env vars:
#   NEW_VERSION, NEW_BUILD_PATH, SERVER_FILE, BUILD_SRC_HOST, BUILD_SRC_USER, BUILD_SRC_BASE,
#   BUILD_SRC_PASS (optional), CN_USER/CN_KEY or CN_PASS (set by the pipeline), EXTRACT_BUILD_TARBALLS
exec bash -euo pipefail "$WORKER"
