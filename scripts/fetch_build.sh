#!/bin/bash
# fetch_build.sh — fetch build tarballs before install
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

# Optional: let pipelines override the local writable root if NEW_BUILD_PATH is not writable.
LOCAL_ROOT_FALLBACK="${LOCAL_ROOT_FALLBACK:-}"

# -------- derive names --------
BASE_VER="$(printf '%s' "$NEW_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
TAG=""
if [[ "$NEW_VERSION" == *_* ]]; then TAG="${NEW_VERSION##*_}"; fi

TRIL_FILE="TRILLIUM_5GCN_CNF_REL_${BASE_VER}.tar.gz"
BIN_GLOB="*BIN_REL_${BASE_VER}.tar.gz"

# -------- normalize weird inputs like .../6.3.0_EA2 → .../6.3.0/EA2 --------
normalize_version_segment() {
  local p="$1"
  if [[ -n "$TAG" ]]; then
    case "$p" in
      *"/${BASE_VER}_${TAG}"|*"/${BASE_VER}_${TAG}/"*)
        p="$(printf '%s' "$p" | sed -E "s#/${BASE_VER}_${TAG}(\/|$)#/${BASE_VER}/${TAG}\1#")"
        ;;
    esac
  fi
  printf '%s' "$p"
}
NEW_BUILD_PATH="$(normalize_version_segment "$NEW_BUILD_PATH")"

# -------- choose destination dir intelligently --------
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

# -------- ensure DEST_DIR is writable; fallback if needed --------
choose_fallback_root() {
  # priority: LOCAL_ROOT_FALLBACK → WORKSPACE → HOME → /var/lib/jenkins/cnbuilds
  if [[ -n "${LOCAL_ROOT_FALLBACK}" && -w "${LOCAL_ROOT_FALLBACK%/}" ]]; then
    printf '%s' "${LOCAL_ROOT_FALLBACK%/}"
    return
  fi
  if [[ -n "${WORKSPACE:-}" && -w "${WORKSPACE%/}" ]]; then
    printf '%s' "${WORKSPACE%/}"
    return
  fi
  if [[ -n "${HOME:-}" && -w "${HOME%/}" ]]; then
    printf '%s' "${HOME%/}"
    return
  fi
  # last resort
  mkdir -p /var/lib/jenkins/cnbuilds 2>/dev/null || true
  printf '%s' "/var/lib/jenkins/cnbuilds"
}

ensure_local_dest() {
  local parent suffix fb
  parent="$(dirname "$DEST_DIR")"
  # Try to create parent → then DEST_DIR
  if mkdir -p "$parent" 2>/dev/null && mkdir -p "$DEST_DIR" 2>/dev/null; then
    return 0
  fi

  # Not writable → compute a fallback that preserves the suffix after the first non-writable segment.
  # The suffix we want to keep is "<BASE_VER>[/<TAG>]".
  if [[ -n "$TAG" ]]; then
    suffix="${BASE_VER}/${TAG}"
  else
    suffix="${BASE_VER}"
  fi

  fb="$(choose_fallback_root)"
  DEST_DIR="${fb}/${suffix}"
  mkdir -p "$DEST_DIR"
  echo "ℹ️  NEW_BUILD_PATH not writable for user $(whoami). Using fallback: ${DEST_DIR}"
}
ensure_local_dest

# Warn if path already contains a different tag (e.g., EA3 vs EA2)
if [[ -n "$TAG" && "$DEST_DIR" =~ /${BASE_VER}/EA[0-9]+ ]]; then
  existing_tag="$(printf '%s' "$DEST_DIR" | sed -nE "s#.*${BASE_VER}/(EA[0-9]+).*#\1#p")"
  if [[ -n "$existing_tag" && "$existing_tag" != "$TAG" ]]; then
    echo "⚠️  DEST_DIR has ${existing_tag} but NEW_VERSION tag is ${TAG}. Proceeding anyway: ${DEST_DIR}"
  fi
fi

# Simple lock to avoid concurrent writes
LOCK="${DEST_DIR}/.fetch_build.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "❌ Another fetch is already running for ${DEST_DIR}. Try again later."
  exit 8
fi

# -------- remote search paths --------
ROOT="${BUILD_SRC_BASE%/}"
SEARCH_DIRS=(
  "$ROOT"
  "$ROOT/${BASE_VER}"
  "$ROOT/${NEW_VERSION}"
)

# -------- choose auth (password first; else key) --------
SSH_BASE_OPTS=(-o StrictHostKeyChecking=no)
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

if [[ -n "$BUILD_SRC_HOST" ]]; then
  echo "=== Fetch build ==="
  echo "  NEW_VERSION : $NEW_VERSION"
  echo "  BASE_VER    : $BASE_VER"
  [[ -n "$TAG" ]] && echo "  TAG         : $TAG"
  echo "  Search base : $ROOT"
  echo "  Remote user : $BUILD_SRC_USER@$BUILD_SRC_HOST"
else
  echo "ℹ️  BUILD_SRC_HOST not set → skipping remote fetch."
fi

echo "  Dest (local): $DEST_DIR"
echo "  Require     : $TRIL_FILE"
echo "  Copy (all)  : $BIN_GLOB"

# -------- find a directory that actually contains TRILLIUM --------
if [[ -z "$BUILD_SRC_HOST" ]]; then
  exit 0
fi

FOUND_DIR=""
for cand in "${SEARCH_DIRS[@]}"; do
  if "${SSH_CMD[@]}" "$REMOTE" "test -s '$cand/$TRIL_FILE'"; then
    FOUND_DIR="$cand"; break
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
"${SCP_CMD[@]}" "${REMOTE}:${FOUND_DIR}/${TRIL_FILE}" "${DEST_DIR}/"

if (( ${#BIN_LIST[@]} > 0 )); then
  for full in "${BIN_LIST[@]}"; do
    base="$(basename "$full")"
    echo "📥 Copying BIN: $base"
    "${SCP_CMD[@]}" "${REMOTE}:${full}" "${DEST_DIR}/"
  done
else
  echo "⚠️  No BIN files matching ${BIN_GLOB} in ${FOUND_DIR}"
fi

[[ -s "${DEST_DIR}/${TRIL_FILE}" ]] || { echo "❌ Copy failed: ${TRIL_FILE}"; exit 4; }

# -------- extract (optional) --------
shopt -s nocasematch
if [[ "$EXTRACT_BUILD_TARBALLS" =~ ^(true|yes|1)$ ]]; then
  # Skip if already looks extracted
  if compgen -G "${DEST_DIR}/TRILLIUM_5GCN_CNF_REL_${BASE_VER}" > /dev/null; then
    echo "ℹ️  Detected previous extraction in ${DEST_DIR}; skipping TRILLIUM re-extract."
  else
    echo "📦 Extracting ${TRIL_FILE} into ${DEST_DIR}..."
    tar -C "${DEST_DIR}" -xzf "${DEST_DIR}/${TRIL_FILE}"
  fi

  for full in "${BIN_LIST[@]}"; do
    base="$(basename "$full")"
    if [[ -s "${DEST_DIR}/${base}" ]]; then
      base_dir="${DEST_DIR}/${base%.tar.gz}"
      if [[ -d "$base_dir" ]]; then
        echo "ℹ️  ${base} appears extracted; skipping."
      else
        echo "📦 Extracting ${base} into ${DEST_DIR}..."
        tar -C "${DEST_DIR}" -xzf "${DEST_DIR}/${base}"
      fi
    fi
  done
else
  echo "ℹ️  Skipping extraction (EXTRACT_BUILD_TARBALLS=${EXTRACT_BUILD_TARBALLS})."
fi
shopt -u nocasematch

echo "✅ Fetch build done. Files are in: ${DEST_DIR}"
