#!/usr/bin/env bash
# scripts/fetch_build.sh
# Copy TRILLIUM + BIN tarballs to each CN server and extract them THERE (not on Jenkins).
# Reads CN hosts from SERVER_FILE (e.g., server_pci_map.txt).
#
# REQUIRED ENVs (set by Jenkins):
#   NEW_VERSION         e.g. 6.3.0_EA2  or 6.3.0
#   NEW_BUILD_PATH      e.g. /home/labadmin or /home/labadmin/6.3.0[/EAx]
#   SERVER_FILE         e.g. server_pci_map.txt
#   BUILD_SRC_HOST      build repo host (where tarballs live)
#   BUILD_SRC_USER      user at build repo host
#   BUILD_SRC_BASE      path on build repo host containing version dirs or tarballs
#   (Auth for build source) either BUILD_SRC_PASS or BUILD_SRC_KEY
#   (Auth for CN)         either CN_PASS or CN_KEY, plus CN_USER
#
# OPTIONAL ENVs:
#   EXTRACT_BUILD_TARBALLS=true|false (default true)
#   CN_USER=labadmin (default)
#   BUILD_SRC_USER=labadmin (default)
#   BUILD_SRC_KEY=/var/lib/jenkins/.ssh/jenkins_key (default)
#   CN_KEY=/var/lib/jenkins/.ssh/jenkins_key (default)
#
# EXIT CODES:
#   1: worker/script missing or generic failure
#   2: missing sshpass when password auth requested
#   3: TRILLIUM tarball not found on build source
#   5: SERVER_FILE missing or unreadable

set -euo pipefail

# -------- Inputs --------
NEW_VERSION="${NEW_VERSION:?NEW_VERSION is required}"             # e.g., 6.3.0_EA2
NEW_BUILD_PATH="${NEW_BUILD_PATH:?NEW_BUILD_PATH is required}"     # e.g., /home/labadmin or /home/labadmin/6.3.0[/EAx]
SERVER_FILE="${SERVER_FILE:-server_pci_map.txt}"

BUILD_SRC_HOST="${BUILD_SRC_HOST:?BUILD_SRC_HOST is required}"
BUILD_SRC_USER="${BUILD_SRC_USER:-labadmin}"
BUILD_SRC_BASE="${BUILD_SRC_BASE:-/repo/builds}"
BUILD_SRC_PASS="${BUILD_SRC_PASS:-}"                                # if set → sshpass
BUILD_SRC_KEY="${BUILD_SRC_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"

CN_USER="${CN_USER:-labadmin}"
CN_PASS="${CN_PASS:-}"                                              # if set → sshpass
CN_KEY="${CN_KEY:-/var/lib/jenkins/.ssh/jenkins_key}"

EXTRACT_BUILD_TARBALLS="${EXTRACT_BUILD_TARBALLS:-true}"

# -------- Version parsing --------
BASE_VER="$(printf '%s' "$NEW_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
TAG=""
if [[ "$NEW_VERSION" == *_* ]]; then TAG="${NEW_VERSION##*_}"; fi

TRIL_FILE="TRILLIUM_5GCN_CNF_REL_${BASE_VER}.tar.gz"
BIN_GLOB="*BIN_REL_${BASE_VER}.tar.gz"

# -------- Normalize NEW_BUILD_PATH like .../6.3.0_EA2 -> .../6.3.0/EA2 --------
if [[ -n "$TAG" ]] && [[ "$NEW_BUILD_PATH" == *"/${BASE_VER}_${TAG}"* ]]; then
  NEW_BUILD_PATH="$(printf '%s' "$NEW_BUILD_PATH" | sed -E "s#/${BASE_VER}_${TAG}(\/|$)#/${BASE_VER}/${TAG}\1#")"
fi

# -------- Compute DEST_DIR base (on CN) --------
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
  command -v sshpass >/dev/null 2>&1 || { echo "❌ sshpass missing (needed for BUILD_SRC_PASS)"; exit 2; }
  b_ssh=(sshpass -p "$BUILD_SRC_PASS" ssh "${ssh_opts[@]}")
  b_scp=(sshpass -p "$BUILD_SRC_PASS" scp -q "${ssh_opts[@]}")
else
  [[ -f "$BUILD_SRC_KEY" ]] || { echo "❌ Build source key not found: $BUILD_SRC_KEY"; exit 2; }
  b_ssh=(ssh -i "$BUILD_SRC_KEY" "${ssh_opts[@]}")
  b_scp=(scp -q -i "$BUILD_SRC_KEY" "${ssh_opts[@]}")
fi

c_ssh=() ; c_scp=()
if [[ -n "$CN_PASS" ]]; then
  command -v sshpass >/dev/null 2>&1 || { echo "❌ sshpass missing (needed for CN_PASS)"; exit 2; }
  c_ssh=(sshpass -p "$CN_PASS" ssh "${ssh_opts[@]}")
  c_scp=(sshpass -p "$CN_PASS" scp -q "${ssh_opts[@]}")
else
  [[ -f "$CN_KEY" ]] || { echo "❌ CN key not found: $CN_KEY"; exit 2; }
  c_ssh=(ssh -i "$CN_KEY" "${ssh_opts[@]}")
  c_scp=(scp -q -i "$CN_KEY" "${ssh_opts[@]}")
fi

REMOTE_BUILD="${BUILD_SRC_USER}@${BUILD_SRC_HOST}"

# -------- Locate source dir on build host --------
ROOT="${BUILD_SRC_BASE%/}"
SEARCH_DIRS=("$ROOT" "$ROOT/${BASE_VER}" "$ROOT/${NEW_VERSION}")

FOUND_DIR=""
for cand in "${SEARCH_DIRS[@]}"; do
  if "${b_ssh[@]}" "$REMOTE_BUILD" "test -s '$cand/$TRIL_FILE'"; then
    FOUND_DIR="$cand"; break
  fi
done
if [[ -z "$FOUND_DIR" ]]; then
  echo "❌ ${TRIL_FILE} not found under:"
  printf '   - %s\n' "${SEARCH_DIRS[@]}"
  exit 3
fi
echo "✅ Build source dir: $FOUND_DIR"

# -------- List BINs --------
readarray -t BIN_LIST < <( "${b_ssh[@]}" "$REMOTE_BUILD" "ls -1 '$FOUND_DIR'/$BIN_GLOB 2>/dev/null || true" )
echo "ℹ️  BIN files found: ${#BIN_LIST[@]}"

# -------- Copy helper: two-step via temp (re-uses local cache for multi-host) --------
TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

download_from_build() {
  local src_file="$1"  # absolute path on build source (FOUND_DIR/filename)
  local base; base="$(basename "$src_file")"
  if [[ ! -s "$TMPDIR/$base" ]]; then
    echo "⬇️  Downloading: $base"
    "${b_scp[@]}" "${REMOTE_BUILD}:${src_file}" "${TMPDIR}/"
  fi
}

upload_to_cn() {
  local base="$1" cn_host="$2" dest_dir="$3"
  echo "📥 Uploading: $base -> ${cn_host}:${dest_dir}"
  "${c_scp[@]}" "${TMPDIR}/${base}" "${CN_USER}@${cn_host}:${dest_dir}/"
}

# -------- Server file parsing helpers --------
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# parse_server_line prints: "<host> <dest_override>" or returns 1 to skip
parse_server_line() {
  local line="$1" host="" dest_override=""
  line="${line%%#*}"           # strip comments
  line="$(echo "$line" | xargs)"  # trim
  [[ -z "$line" ]] && return 1

  # tokens split on whitespace/colon
  # shellcheck disable=SC2206
  local toks=($(echo "$line" | awk -F'[: \t]+' '{for(i=1;i<=NF;i++)print $i}'))

  # Prefer an IPv4 token; else first non-path token
  for t in "${toks[@]}"; do
    if is_ipv4 "$t"; then host="$t"; break; fi
  done
  if [[ -z "$host" ]]; then
    for t in "${toks[@]}"; do
      [[ "$t" == /* ]] && continue
      host="$t"; break
    done
  fi
  [[ -z "$host" ]] && return 1

  # Optional third colon field as per-host base override (absolute path)
  local c1 c2 c3
  IFS=':' read -r c1 c2 c3 _ <<<"$line"
  if [[ -n "${c3:-}" && "$c3" == /* ]]; then
    dest_override="$c3"
  fi

  echo "$host" "$dest_override"
  return 0
}

# -------- Iterate servers --------
[[ -f "$SERVER_FILE" ]] || { echo "❌ SERVER_FILE not found: $SERVER_FILE"; exit 5; }

while IFS= read -r raw; do
  parsed="$(parse_server_line "$raw")" || continue
  host="$(echo "$parsed" | awk '{print $1}')"
  host_dest_override="$(echo "$parsed" | awk '{print $2}')"

  # Decide per-host destination
  per_host_dest="$DEST_DIR"
  if [[ -n "$host_dest_override" ]]; then
    per_host_dest="$host_dest_override"
    case "$per_host_dest" in
      *"/${BASE_VER}/"*|*"/${BASE_VER}") : ;;
      *)
        if [[ -n "$TAG" ]]; then per_host_dest="${per_host_dest%/}/${BASE_VER}/${TAG}"
        else                       per_host_dest="${per_host_dest%/}/${BASE_VER}"
        fi
        ;;
    esac
    if [[ -n "$TAG" && "$per_host_dest" == */"${BASE_VER}" ]]; then
      per_host_dest="${per_host_dest}/${TAG}"
    fi
  fi

  echo ""
  echo "🧩 Target CN: $host"
  echo "📁 Dest dir : $per_host_dest"

  # 1) Ensure destination exists on CN
  "${c_ssh[@]}" "${CN_USER}@${host}" "mkdir -p '$per_host_dest'"

  # 2) TRILLIUM: download once, upload to this CN
  download_from_build "${FOUND_DIR}/${TRIL_FILE}"
  upload_to_cn "${TRIL_FILE}" "$host" "$per_host_dest"

  # 3) BINs
  if (( ${#BIN_LIST[@]} > 0 )); then
    for full in "${BIN_LIST[@]}"; do
      base="$(basename "$full")"
      download_from_build "$full"
      upload_to_cn "$base" "$host" "$per_host_dest"
    done
  else
    echo "⚠️  No BINs matching $BIN_GLOB in $FOUND_DIR"
  fi

  # 4) Extract on CN (optional)
  shopt -s nocasematch
  if [[ "$EXTRACT_BUILD_TARBALLS" =~ ^(true|yes|1)$ ]]; then
    echo "📦 Extracting on $host ..."
    # TRILLIUM
    if "${c_ssh[@]}" "${CN_USER}@${host}" "test -d '$per_host_dest/TRILLIUM_5GCN_CNF_REL_${BASE_VER}'"; then
      echo "ℹ️  TRILLIUM already extracted; skipping."
    else
      "${c_ssh[@]}" "${CN_USER}@${host}" "tar -C '$per_host_dest' -xzf '$per_host_dest/$TRIL_FILE'"
    fi
    # BINs
    if (( ${#BIN_LIST[@]} > 0 )); then
      for full in "${BIN_LIST[@]}"; do
        base="$(basename "$full")"
        base_dir="${base%.tar.gz}"
        if "${c_ssh[@]}" "${CN_USER}@${host}" "test -d '$per_host_dest/$base_dir'"; then
          echo "ℹ️  $base already extracted; skipping."
        else
          "${c_ssh[@]}" "${CN_USER}@${host}" "tar -C '$per_host_dest' -xzf '$per_host_dest/$base'"
        fi
      done
    fi
  else
    echo "ℹ️  Extraction disabled (EXTRACT_BUILD_TARBALLS=${EXTRACT_BUILD_TARBALLS})."
  fi
  shopt -u nocasematch

  echo "✅ Done for $host → $per_host_dest"
done < "$SERVER_FILE"

echo ""
echo "🎉 All CN servers processed successfully."
