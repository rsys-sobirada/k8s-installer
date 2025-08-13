#!/bin/bash
# scripts/cluster_install.sh
# Sequential install per server
# - Always uses NEW_BUILD_PATH as the root where builds reside (normalized to /<BASE>[/<TAG>])
# - Pre-check: create /mnt/data{0,1,2} and clear contents
# - Only untars TRILLIUM_5GCN_CNF_REL_<BASE>.tar.gz (no BINs)
# - CN login via SSH key (root@host) like cluster_reset.sh

set -euo pipefail

# ---- helpers ----
require(){ local n="$1" ex="$2"; [[ -n "${!n:-}" ]] || { echo "❌ Missing $n (e.g. $ex)"; exit 1; }; }
base_ver(){ echo "${1%%_*}"; }                                   # 6.3.0_EA2 -> 6.3.0
ver_tag(){ [[ "$1" == *_* ]] && echo "${1##*_}" || echo ""; }    # 6.3.0_EA2 -> EA2 ; 6.3.0 -> ""

# Build final kubespray path: <root>/<BASE>/<TAG>/TRILLIUM_.../k8s-vX.Y.Z
make_k8s_path(){  # <root> <BASE> <TAG> <K8S_VER> [REL_SUFFIX]
  local root="${1%/}" base="$2" tag="$3" kver="$4" rel="${5-}"
  echo "$root/${base}/${tag}/TRILLIUM_5GCN_CNF_REL_${base}${rel}/common/tools/install/k8s-v${kver}"
}

# If NEW_BUILD_PATH already ends with /<BASE> or /<BASE>/<TAG>, strip it to get ROOT
normalize_root(){
  # <path> <BASE> [TAG]
  local p="${1%/}" base="$2" tag="${3-}"
  if [[ -n "$tag" && "$p" == */"$base"/"$tag" ]]; then
    p="${p%/$base/$tag}"
  elif [[ "$p" == */"$base" ]]; then
    p="${p%/$base}"
  else
    case "$p" in */"$base"/EA*) p="${p%/$base/*}";; esac
  fi
  echo "${p:-/}"
}

# ---- inputs ----
require NEW_VERSION     "6.3.0_EA2"
require NEW_BUILD_PATH  "/home/labadmin"
: "${K8S_VER:=1.31.4}"
: "${REL_SUFFIX:=}"                              # usually empty
: "${SSH_KEY:=/var/lib/jenkins/.ssh/jenkins_key}"
: "${INSTALL_SERVER_FILE:=server_pci_map.txt}"   # supports "name:ip" or just "ip"
: "${INSTALL_IP_ADDR:=10.10.10.20/24}"
: "${INSTALL_IP_IFACE:=}"                        # optional forced iface

[[ -f "$SSH_KEY" ]] || { echo "❌ SSH key not found: $SSH_KEY"; exit 1; }
chmod 600 "$SSH_KEY" || true
[[ -f "$INSTALL_SERVER_FILE" ]] || { echo "❌ Missing $INSTALL_SERVER_FILE"; exit 1; }

# SSH speed-ups
SSH_OPTS='-o BatchMode=yes -o StrictHostKeyChecking=no -o ControlMaster=auto -o ControlPersist=5m -o ControlPath=/tmp/ssh_mux_%h_%p_%r'

BASE="$(base_ver "$NEW_VERSION")"
TAG_IN="$(ver_tag "$NEW_VERSION")"   # may be empty if NEW_VERSION=6.3.0

echo "NEW_VERSION:      $NEW_VERSION"
echo "NEW_BUILD_PATH:   $NEW_BUILD_PATH"
echo "BASE version:     $BASE"
[[ -n "$TAG_IN" ]] && echo "Provided TAG:   $TAG_IN" || echo "Provided TAG:   (none; will detect per host)"
echo "INSTALL_LIST:     $INSTALL_SERVER_FILE"
echo "IP to ensure:     $INSTALL_IP_ADDR"
[[ -n "$INSTALL_IP_IFACE" ]] && echo "Forced iface:    $INSTALL_IP_IFACE"
echo "────────────────────────────────────────"

# ---- remote snippets ----

# Create /mnt/{data0,data1,data2} and clear their contents
read -r -d '' PREPARE_MNT_SNIPPET <<'RSCRIPT' || true
set -euo pipefail
prep() {
  local d="$1"
  mkdir -p "$d"
  if [ -d "$d" ]; then
    find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  fi
}
prep /mnt/data0
prep /mnt/data1
prep /mnt/data2
echo "[MNT] Prepared /mnt/data{0,1,2} (created if missing, contents cleared)"
RSCRIPT

# Ensure alias IP exists
# $1=IP/CIDR, $2=forced_iface_or_empty
read -r -d '' ENSURE_IP_SNIPPET <<'RSCRIPT' || true
set -euo pipefail
IP_CIDR="$1"; FORCE_IFACE="${2-}"
present() { ip -4 addr show | grep -q -E "[[:space:]]${IP_CIDR%/*}(/|[[:space:]])"; }
if present; then echo "[IP] Present: ${IP_CIDR}"; exit 0; fi
IFACE="$FORCE_IFACE"
if [[ -z "$IFACE" ]]; then
  if command -v lshw >/dev/null 2>&1; then
    IFACE="$(lshw -quiet -c network -businfo 2>/dev/null | awk 'NR>2 && $2 != "" {print $2}' \
             | grep -E "^(en|eth|ens|eno|em|bond)[0-9]+" | head -n1 || true)"
  fi
  if [[ -z "$IFACE" ]]; then
    IFACE="$(ip -o link | awk -F': ' '{print $2}' | grep -E "^(en|eth|ens|eno|em|bond)" | head -n1 || true)"
  fi
  [[ -z "$IFACE" ]] && IFACE="lo"
fi
ip addr replace "$IP_CIDR" dev "$IFACE" || true
echo "[IP] Plumbed $IP_CIDR on ${IFACE} (iface may remain DOWN)"
RSCRIPT

# Ensure ONLY TRILLIUM is extracted under <ROOT>/<BASE>/<TAG>
# $1=root_base_dir (normalized), $2=BASE, $3=TAG, $4=REL_SUFFIX
read -r -d '' ENSURE_TRILLIUM_EXTRACTED <<'RSCRIPT' || true
set -euo pipefail
ROOT="$1"; BASE="$2"; TAG="$3"; REL="${4-}"
DEST_DIR="$ROOT/$BASE/$TAG"
TRIL_DIR="$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE}${REL}"
TRIL_TAR="$DEST_DIR/TRILLIUM_5GCN_CNF_REL_${BASE}.tar.gz"

mkdir -p "$DEST_DIR"

if [[ -d "$TRIL_DIR" ]]; then
  echo "[TRIL] Already extracted at $TRIL_DIR"
  exit 0
fi

if [[ -s "$TRIL_TAR" ]]; then
  echo "[TRIL] Extracting $TRIL_TAR into $DEST_DIR ..."
  tar -C "$DEST_DIR" -xzf "$TRIL_TAR"
  [[ -d "$TRIL_DIR" ]] || { echo "[ERROR] Extraction completed but $TRIL_DIR not found"; exit 2; }
else
  echo "[ERROR] TRILLIUM tar not found at $TRIL_TAR"
  exit 2
fi
RSCRIPT

# Run installer in computed k8s path
# $1=install_path
read -r -d '' RUN_INSTALL_SNIPPET <<'RSCRIPT' || true
set -euo pipefail
P="$1"
cd "$P" || { echo "[ERROR] Path not found: $P"; exit 2; }
sed -i 's/\r$//' install_k8s.sh 2>/dev/null || true
echo "[RUN] yes yes | ./install_k8s.sh (in $P)"
yes yes | bash ./install_k8s.sh
RSCRIPT

any_failed=0

# ---- iterate servers ----
# supports "name:ip" or just "ip" (any extra fields are ignored)
while IFS= read -r raw || [[ -n "${raw:-}" ]]; do
  line="$(echo -n "${raw:-}" | tr -d '\r')"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

  host=""
  if [[ "$line" == *:* ]]; then
    IFS=':' read -r _name ip _rest <<<"$line"
    host="$(echo -n "${ip:-}" | xargs)"
  else
    host="$(echo -n "$line" | xargs)"
  fi
  [[ -z "$host" ]] && { echo "⚠️  Skipping malformed line: $line"; continue; }

  # 0) Pre-check: prepare /mnt/data{0,1,2}
  ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s <<<"$PREPARE_MNT_SNIPPET"

  # 1) Normalize ROOT from NEW_BUILD_PATH (ignore any per-host override)
  raw_base="$NEW_BUILD_PATH"
  ROOT_BASE="$(normalize_root "$raw_base" "$BASE")"

  # 2) Determine TAG for this host:
  TAG="$TAG_IN"
  if [[ -z "$TAG" ]]; then
    TAG="$(ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$ROOT_BASE" "$BASE" <<'RSCRIPT'
set -euo pipefail
BDIR="$1"; BASE="$2"
shopt -s nullglob
# choose the "latest" EA* by version-like sort if multiple exist
cands=( "$BDIR/$BASE"/EA* )
if (( ${#cands[@]} > 0 )); then
  for i in "${!cands[@]}"; do cands[$i]="$(basename "${cands[$i]}")"; done
  printf '%s\n' "${cands[@]}" | sort -V | tail -n1
else
  echo "EA1"
fi
RSCRIPT
    )" || TAG="EA1"
  fi

  # 3) Re-normalize ROOT if NEW_BUILD_PATH was /<BASE> or /<BASE>/<TAG>
  ROOT_BASE="$(normalize_root "$raw_base" "$BASE" "$TAG")"

  # 4) Ensure ONLY TRILLIUM is extracted under ROOT_BASE/<BASE>/<TAG>
  if ! ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$ROOT_BASE" "$BASE" "$TAG" "$REL_SUFFIX" <<<"$ENSURE_TRILLIUM_EXTRACTED"; then
    echo "❌ Failed to ensure TRILLIUM extracted on $host under $ROOT_BASE/$BASE/$TAG"
    any_failed=1
    continue
  fi

  # 5) Compose final kubespray path and run installer
  NEW_VER_PATH="$(make_k8s_path "$ROOT_BASE" "$BASE" "$TAG" "$K8S_VER" "$REL_SUFFIX")"

  echo ""
  echo "🧩 Host:  $host"
  echo "📁 Root:  $ROOT_BASE   (derived from NEW_BUILD_PATH)"
  echo "🏷️  Tag:   $TAG"
  echo "📁 Path:  $NEW_VER_PATH"

  # Ensure the alias IP exists
  if ! ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$INSTALL_IP_ADDR" "$INSTALL_IP_IFACE" <<<"$ENSURE_IP_SNIPPET"; then
    echo "❌ Failed to ensure $INSTALL_IP_ADDR on $host"
    any_failed=1
    continue
  fi

  # Run installer with auto-confirm
  if ! ssh $SSH_OPTS -i "$SSH_KEY" "root@$host" bash -s -- "$NEW_VER_PATH" <<<"$RUN_INSTALL_SNIPPET"; then
    echo "❌ install_k8s.sh failed on $host"
    any_failed=1
    continue
  fi

  echo "✅ Install triggered on $host"
done < "$INSTALL_SERVER_FILE"

echo ""
if [[ $any_failed -ne 0 ]]; then
  echo "❌ One or more installs failed."
  exit 1
fi
echo "🎉 Install step completed (installer invoked on all hosts)."
