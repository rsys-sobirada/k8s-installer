#!/usr/bin/env bash
# scripts/nf_config.sh — Configure NF YAMLs on CNs
# Env (required): SERVER_FILE, SSH_KEY, NEW_BUILD_PATH, NEW_VERSION, DEPLOYMENT_TYPE
# Env (optional): HOST_USER (default root)
# Server map line format (no spaces): NAME:HOST:OLD_BUILD:MODE:N3:N6:N4:AMF
#   - N3/N6 may be PCI (0000:08:00.0) or iface name (e.g., enp3s0f0)
#   - N4 is IPv4 CIDR (e.g., 10.11.10.0/30)
#   - AMF is IPv4 (e.g., 12.12.1.100)

set -euo pipefail

# ---- required envs ----
: "${SERVER_FILE:?missing SERVER_FILE}"
: "${SSH_KEY:?missing SSH_KEY}"
: "${NEW_BUILD_PATH:?missing NEW_BUILD_PATH}"
: "${NEW_VERSION:?missing NEW_VERSION}"
: "${DEPLOYMENT_TYPE:?missing DEPLOYMENT_TYPE}"
HOST_USER="${HOST_USER:-root}"

VER="${NEW_VERSION%%_*}"   # e.g. 6.3.0 from 6.3.0_EA3
case "${DEPLOYMENT_TYPE}" in
  [Ll]ow) CAP="LOW" ;;
  [Hh]igh) CAP="HIGH" ;;
  *) CAP="MEDIUM" ;;
esac

echo "[nf_config] NEW_BUILD_PATH=${NEW_BUILD_PATH}"
echo "[nf_config] NEW_VERSION=${NEW_VERSION} (VER=${VER})"
echo "[nf_config] DEPLOYMENT_TYPE=${DEPLOYMENT_TYPE} (CAP=${CAP})"
echo "[nf_config] SERVER_FILE=${SERVER_FILE}"

# --- parse server file lines (ignore blanks/comments). No spaces allowed in fields. ---
mapfile -t MAPLINES < <(awk 'NF && $1 !~ /^#/' "${SERVER_FILE}")

for RAW in "${MAPLINES[@]}"; do
  # strip spaces/tabs just in case
  LINE="$(printf '%s' "${RAW}" | tr -d '[:space:]')"

  # parse from the RIGHT to avoid breaking on PCI colons
  work="${LINE}"

  AMF_IP="${work##*:}";   work="${work%:*}"          # last
  N4_CIDR="${work##*:}";  work="${work%:*}"          # last-1
  N6_VAL="${work##*:}";   work="${work%:*}"          # last-2
  N3_VAL="${work##*:}";   work="${work%:*}"          # last-3
  MODE="${work##*:}";     work="${work%:*}"          # last-4
  HOST="${work##*:}";     work="${work%:*}"          # last-5 (name left in $work but unused)

  if [[ -z "${HOST}" || -z "${MODE}" || -z "${N3_VAL}" || -z "${N6_VAL}" || -z "${N4_CIDR}" || -z "${AMF_IP}" ]]; then
    echo "[nf_config] skip malformed line: ${RAW}"
    continue
  fi

  echo "[nf_config][${HOST}] ▶ start"
  echo "[nf_config][${HOST}] parsed: MODE='${MODE}' N3='${N3_VAL}' N6='${N6_VAL}' N4='${N4_CIDR}' AMF='${AMF_IP}'"

  NF_ROOT="${NEW_BUILD_PATH%/}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"

  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${HOST}" bash -se -- "${NF_ROOT}" "${MODE}" "${N3_VAL}" "${N6_VAL}" "${N4_CIDR}" "${AMF_IP}" "${CAP}" "${HOST}" "${VER}" <<'EOSH'
set -euo pipefail
NF_ROOT="$1"; MODE_IN="$2"; N3_IN="$3"; N6_IN="$4"; N4_IN="$5"; AMF_IP="$6"; CAPACITY="$7"; HOST_IP="$8"; VER="$9"

UPF="${NF_ROOT}/upf-1-values.yaml"
SMF="${NF_ROOT}/smf-1-values.yaml"
AMF="${NF_ROOT}/amf-1-values.yaml"
GV="${NF_ROOT}/global-values.yaml"

echo "[remote] NF_ROOT=${NF_ROOT}"
for f in "$UPF" "$SMF" "$AMF" "$GV"; do
  [[ -f "$f" ]] || { echo "[remote] ERROR: missing $f"; exit 3; }
done

# ---- helpers ----
is_pci() { [[ "$1" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-9A-Fa-f]$ ]]; }

resolve_pci() {
  # arg can be PCI (pass-through), iface name, or empty
  local t="$1"; local bus=""
  if is_pci "$t"; then echo "$t"; return 0; fi
  if [[ -z "${t}" ]]; then echo ""; return 0; fi
  if [[ -d "/sys/class/net/${t}" ]]; then
    # try ethtool
    if command -v ethtool >/dev/null 2>&1; then
      bus=$(ethtool -i "$t" 2>/dev/null | awk '/bus-info:/ {print $2}') || true
      if is_pci "$bus"; then echo "$bus"; return 0; fi
    fi
    # try sysfs link
    bus=$(basename "$(readlink -f "/sys/class/net/$t/device" 2>/dev/null)" 2>/dev/null) || true
    if is_pci "$bus"; then echo "$bus"; return 0; fi
  fi
  echo ""
}

patch_key_scalar() { # file key value    (replaces first "key: ..." line)
  awk -v key="$2" -v val="$3" '
    !done && $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
      i=match($0,/[^[:space:]]/); ind=(i?substr($0,1,i-1):"");
      print ind key ": " val; done=1; next
    } { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

patch_first_range_ipv4() {  # file CIDR => replace first IPv4 "range": "A.B.C.D/M"
  awk -v rng="$2" '
    BEGIN{ipam=0; ranges=0; done=0}
    {
      if ($0 ~ /"ipam"[[:space:]]*:[[:space:]]*\{/) ipam=1
      if (ipam && $0 ~ /"ipRanges"[[:space:]]*:[[:space:]]*\[/) ranges=1
      if (ranges && !done && $0 ~ /"range":[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/) {
        i=match($0,/[^[:space:]]/); ind=(i?substr($0,1,i-1):"");
        print ind "\"range\": \"" rng "\""; done=1; next
      }
      print
      if (ranges && $0 ~ /\]/) ranges=0
      if (ipam && !ranges && $0 ~ /\}/) ipam=0
    }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

patch_first_exclude_ipv4() { # file A.B.C.D/32 => replace first IPv4 /32 inside "exclude"
  awk -v exc="$2" '
    BEGIN{ipam=0; ex=0; done=0}
    {
      if ($0 ~ /"ipam"[[:space:]]*:[[:space:]]*\{/) ipam=1
      if (ipam && $0 ~ /"exclude"[[:space:]]*:[[:space:]]*\[/) ex=1
      if (ex && !done && $0 ~ /"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/32"/) {
        i=match($0,/[^[:space:]]/); ind=(i?substr($0,1,i-1):"");
        print ind "\"" exc "\""; done=1; next
      }
      print
      if (ex && $0 ~ /\]/) ex=0
      if (ipam && !ex && $0 ~ /\}/) ipam=0
    }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ---- normalize line endings (avoid awk weirdness) ----
sed -i 's/\r$//' "$UPF" "$SMF" "$AMF" "$GV"

# ---- global-values.yaml tweaks ----
patch_key_scalar "$GV" "capacitySetup" "\"${CAPACITY}\""
patch_key_scalar "$GV" "ingressExtFQDN" "${HOST_IP}.nip.io"
if [[ "${CAPACITY}" == "LOW" ]]; then
  patch_key_scalar "$GV" "k8sCpuMgrStaticPolicyEnable" "false"
fi
echo "[remote] global-values.yaml updated."

# ---- bump image tags v1 -> VER in this folder only ----
find "${NF_ROOT}" -maxdepth 1 -type f -name "*.yaml" -print0 | \
  xargs -0 sed -i -E 's/(image:[[:space:]]*"[^"]*:)v1(")/\1'"${VER}"'\2/g'
echo "[remote] replaced image tag v1 -> ${VER} in nf-services/scripts."

# ---- AMF NGC external IP under the comment, with fallback to externalIP: key ----
if [[ -n "${AMF_IP:-}" && "${AMF_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  awk -v ip="$AMF_IP" '
    {
      line=$0
      if (mark) {
        if (line ~ /^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+([[:space:]]*#.*)?$/) {
          i=match(line,/[^[:space:]]/); ind=(i?substr(line,1,i-1):"");
          print ind ip; mark=0; next
        }
      }
      if (line ~ /# *NGC IP for external Communication/) { print line; mark=1; next }
      print line
    }' "$AMF" > "$AMF.tmp" && mv "$AMF.tmp" "$AMF"

  # also update an explicit key if present
  sed -i -E 's/^([[:space:]]*externalIP:).*/\1 '"${AMF_IP}"'/' "$AMF"
fi

# ---- UPF intfConfig type based on MODE (if block exists) ----
MODE_UP="$(printf '%s' "${MODE_IN}" | tr '[:lower:]' '[:upper:]')"
if grep -qE '^ *intfConfig:' "$UPF"; then
  if [[ "${MODE_UP}" == "VM" ]]; then
    sed -i -e '/^ *intfConfig:/,/^ *upfsesscoresteps:/{
      s/^\([[:space:]]*type:\).*/\1 "devPassthrough"/
    }' "$UPF"
  else
    sed -i -e '/^ *intfConfig:/,/^ *upfsesscoresteps:/{
      s/^\([[:space:]]*type:\).*/\1 "sriov"/
    }' "$UPF"
  fi
fi

# ---- resolve N3/N6 to PCI (if iface names were provided) ----
N3_PCI="$(resolve_pci "${N3_IN}")"
N6_PCI="$(resolve_pci "${N6_IN}")"

# ---- inject PCI inside correct interface blocks using sed ranges (BusyBox/GNU sed safe) ----
# N3 (nguInterface) pciAddress within nguInterface: ... until n6Interface_0:
if [[ -n "${N3_PCI}" ]]; then
  sed -i -e '/^ *nguInterface:/,/^ *n6Interface_0:/{
    s/^\([[:space:]]*pciAddress:\).*/\1 '"${N3_PCI}"'/
  }' "$UPF"
fi

# N6 (n6Interface_0) pciAddress within its block until the next header (three possible boundaries)
if [[ -n "${N6_PCI}" ]]; then
  sed -i -e '/^ *n6Interface_0:/,/^ *n6Interface_1:/{
    s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/
  }' "$UPF"
  sed -i -e '/^ *n6Interface_0:/,/^ *n9Interface:/{
    s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/
  }' "$UPF"
  sed -i -e '/^ *n6Interface_0:/,/^ *upfsesscoresteps:/{
    s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/
  }' "$UPF"
fi

# ---- N4 ipam updates: first IPv4 "range" and first IPv4 in "exclude" ----
if [[ -n "${N4_IN:-}" && "${N4_IN}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)\/([0-9]+)$ ]]; then
  base3="${BASH_REMATCH[1]}"; last="${BASH_REMATCH[2]}"; mask="${BASH_REMATCH[3]}"
  N4_RANGE="${base3}.${last}/${mask}"
  EXCL_UPF="${base3}.$((last+1))/32"
  EXCL_SMF="${base3}.$((last+2))/32"

  patch_first_range_ipv4   "$UPF" "${N4_RANGE}"
  patch_first_range_ipv4   "$SMF" "${N4_RANGE}"
  patch_first_exclude_ipv4 "$UPF" "${EXCL_UPF}"
  patch_first_exclude_ipv4 "$SMF" "${EXCL_SMF}"
  echo "[remote] N4_RANGE=${N4_RANGE}  EXCL_UPF=${EXCL_UPF}  EXCL_SMF=${EXCL_SMF}"
else
  echo "[remote] N4_IN invalid or missing — skipping N4 edits"
fi

# ---- sanity prints for the pipeline log ----
echo "[remote] NF checks:"
# AMF line under comment OR explicit key
awk '/# *NGC IP for external Communication/{p=NR+1} NR==p{print "[remote] AMF NGC line: " $0}' "$AMF" || true
grep -nE '^[[:space:]]*externalIP:' "$AMF" | head -1 | sed 's/^/[remote] /' || true
# UPF type
awk '/^ *intfConfig:/{f=1} f&&/^ *type:/{print "[remote] upf.type: "$0; f=0}' "$UPF" || true
# PCI lines
awk '/^ *nguInterface:/{f=1} f&&/^ *pciAddress:/{print "[remote] upf.ngu pci: "$0; f=0}' "$UPF" || true
awk '/^ *n6Interface_0:/{f=1} f&&/^ *pciAddress:/{print "[remote] upf.n6  pci: "$0; f=0}' "$UPF" || true
# ranges/excludes
grep -nE '"range"|exclude' "$UPF" "$SMF" | sed "s|${NF_ROOT}/||" || true

echo "[remote] ✅ NF config complete on ${HOST_IP}"
EOSH

  echo "[nf_config][${HOST}] ◀ done"
done

echo "[nf_config] All hosts processed."
