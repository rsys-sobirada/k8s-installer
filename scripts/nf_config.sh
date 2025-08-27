#!/usr/bin/env bash
# scripts/nf_config.sh — Configure NF YAMLs on CNs (robust exclude IP update)
# Env (required): SERVER_FILE, SSH_KEY, NEW_BUILD_PATH, NEW_VERSION, DEPLOYMENT_TYPE
# Optional: HOST_USER (default root)

set -euo pipefail

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

# ---------- helpers (run remotely) ----------
read -r -d '' REMOTE_SCRIPT <<'EOSH'
set -euo pipefail
NF_ROOT="$1"; MODE_IN="$2"; N3_IN="$3"; N6_IN="$4"; N4_IN="$5"; AMF_IP="$6"; CAPACITY="$7"; HOST_IP="$8"; VER="$9"

UPF="${NF_ROOT}/upf-1-values.yaml"
SMF="${NF_ROOT}/smf-1-values.yaml"
AMF="${NF_ROOT}/amf-1-values.yaml"
GV="${NF_ROOT}/global-values.yaml"

echo "[remote] NF_ROOT=${NF_ROOT}"
for f in "$UPF" "$SMF" "$AMF" "$GV"; do [[ -f "$f" ]] || { echo "[remote] ERROR: missing $f"; exit 3; }; done

# Normalize CRLF
sed -i 's/\r$//' "$UPF" "$SMF" "$AMF" "$GV"

# simple scalar patcher
patch_key_scalar() { # file key value
  awk -v key="$2" -v val="$3" '
    !done && $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
      i=match($0,/[^[:space:]]/); ind=(i?substr($0,1,i-1):"");
      print ind key ": " val; done=1; next
    } { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# capacity + fqdn
patch_key_scalar "$GV" "capacitySetup" "\"${CAPACITY}\""
patch_key_scalar "$GV" "ingressExtFQDN" "${HOST_IP}.nip.io"
if [[ "${CAPACITY}" == "LOW" ]]; then patch_key_scalar "$GV" "k8sCpuMgrStaticPolicyEnable" "false"; fi
echo "[remote] global-values.yaml updated."

# bump image tag v1 -> VER (top-level YAMLs only)
find "${NF_ROOT}" -maxdepth 1 -type f -name "*.yaml" -print0 | xargs -0 sed -i -E 's/(image:[[:space:]]*"[^"]*:)v1(")/\1'"${VER}"'\2/g'
echo "[remote] replaced image tag v1 -> ${VER} in nf-services/scripts."

# AMF IP under comment + explicit key
if [[ -n "${AMF_IP:-}" && "${AMF_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  awk -v ip="$AMF_IP" '
    { line=$0
      if (mark) {
        if (line ~ /^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+([[:space:]]*#.*)?$/) {
          i=match(line,/[^[:space:]]/); ind=(i?substr(line,1,i-1):"");
          print ind ip; mark=0; next
        }
      }
      if (line ~ /# *NGC IP for external Communication/) { print line; mark=1; next }
      print line
    }' "$AMF" > "$AMF.tmp" && mv "$AMF.tmp" "$AMF"
  sed -i -E 's/^([[:space:]]*externalIP:).*/\1 '"${AMF_IP}"'/' "$AMF"
fi

# PCI helpers
is_pci() { [[ "$1" =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{2}:[0-9A-Fa-f]{2}\.[0-9A-Fa-f]$ ]]; }
resolve_pci() {
  local t="$1" bus=""
  if is_pci "$t"; then echo "$t"; return; fi
  [[ -n "$t" && -d "/sys/class/net/$t" ]] || { echo ""; return; }
  if command -v ethtool >/dev/null 2>&1; then
    bus=$(ethtool -i "$t" 2>/dev/null | awk '/bus-info:/ {print $2}') || true
    is_pci "$bus" && { echo "$bus"; return; }
  fi
  bus=$(basename "$(readlink -f "/sys/class/net/$t/device" 2>/dev/null)" 2>/dev/null) || true
  is_pci "$bus" && echo "$bus" || echo ""
}

MODE_UP="$(printf '%s' "${MODE_IN}" | tr '[:lower:]' '[:upper:]')"
# devPassthrough/sriov type guard
if grep -qE '^ *intfConfig:' "$UPF"; then
  if [[ "${MODE_UP}" == "VM" ]]; then
    sed -i -e '/^ *intfConfig:/,/^ *upfsesscoresteps:/ { s/^\([[:space:]]*type:\).*/\1 "devPassthrough"/ }' "$UPF"
  else
    sed -i -e '/^ *intfConfig:/,/^ *upfsesscoresteps:/ { s/^\([[:space:]]*type:\).*/\1 "sriov"/ }' "$UPF"
  fi
fi

N3_PCI="$(resolve_pci "${N3_IN}")"
N6_PCI="$(resolve_pci "${N6_IN}")"

# PCI inject (N3)
if [[ -n "${N3_PCI}" ]]; then
  sed -i -e '/^ *nguInterface:/,/^ *n6Interface_0:/ { s/^\([[:space:]]*pciAddress:\).*/\1 '"${N3_PCI}"'/ }' "$UPF"
fi
# PCI inject (N6)
if [[ -n "${N6_PCI}" ]]; then
  sed -i -e '/^ *n6Interface_0:/,/^ *n6Interface_1:/ { s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/ }' "$UPF"
  sed -i -e '/^ *n6Interface_0:/,/^ *n9Interface:/    { s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/ }' "$UPF"
  sed -i -e '/^ *n6Interface_0:/,/^ *upfsesscoresteps:/ { s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/ }' "$UPF"
fi

# ---------- robust, indentation-aware IPAM editors ----------
# Common awk pieces: count leading indent, detect plain YAML keys
lead() { awk 'function ind(){i=match($0,/[^[:space:]]/); return i?i-1:0} {print ind()}' ; }

# Update UPF: upfsp -> n4 -> "ipam" -> range + exclude[0]
patch_upf_ipam() {
  local file="$1" n4cidr="$2" excl="$3"
  awk -v CIDR="$n4cidr" -v EXC="$excl" '
    function indent(s,   i){ i=match(s,/[^[:space:]]/); return i?i-1:0 }
    function yaml_key(s,  t){ t=s; sub(/^[[:space:]]*/,"",t); sub(/:.*/,"",t); return t }
    BEGIN{in_upfsp=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_ex=0; }
    {
      line=$0; ind=indent(line);
      # detect keys (unquoted) like upfsp:, n4:
      if (match(line,/^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*$/)) {
        key=yaml_key(line)
        # enter/leave upfsp
        if (!in_upfsp && key=="upfsp"){in_upfsp=1; ind_up=ind}
        else if (in_upfsp && ind<=ind_up && key!="upfsp"){in_upfsp=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_ex=0}
        # inside upfsp -> n4
        if (in_upfsp){
          if (!in_n4 && key=="n4"){in_n4=1; ind_n4=ind}
          else if (in_n4 && ind<=ind_n4 && key!="n4"){in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_ex=0}
        }
      }

      # find "ipam": { inside upfsp.n4 (quoted JSON-style key)
      if (in_upfsp && in_n4 && !in_ipam && line ~ /"ipam"[[:space:]]*:[[:space:]]*\{/){in_ipam=1}

      # while in that ipam object
      if (in_upfsp && in_n4 && in_ipam){
        # range under "ipRanges": [
        if (!in_ranges && line ~ /"ipRanges"[[:space:]]*:[[:space:]]*\[/){in_ranges=1}
        else if (in_ranges && line ~ /"range"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"\s*,?$/){
          i=match(line,/[^[:space:]]/); pre=(i?substr(line,1,i-1):""); post=""
          if (line ~ /",[[:space:]]*$/) post=","
          print pre "\"range\": \"" CIDR "\"" post
          next
        } else if (in_ranges && line ~ /\]/){in_ranges=0}

        # exclude list
        if (!in_ex && line ~ /"exclude"[[:space:]]*:[[:space:]]*\[/){
          in_ex=1; i=match(line,/[^[:space:]]/); exind=(i?substr(line,1,i-1):"") "  "
          print line; next
        } else if (in_ex && !wrote_ex && line ~ /^[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"\s*,?$/){
          trail=(line ~ /,[[:space:]]*$/)?",":""; print exind "\"" EXC "\"" trail
          wrote_ex=1; next
        } else if (in_ex && !wrote_ex && line ~ /^[[:space:]]*\]/){
          print exind "\"" EXC "\""
          print line
          in_ex=0; wrote_ex=1; next
        } else if (in_ex && line ~ /\]/){ in_ex=0 } # close exclude

        # leave ipam on closing brace when not inside sub-blocks
        if (in_ipam && !in_ranges && !in_ex && line ~ /^[[:space:]]*\}/){in_ipam=0}
      }

      print line
    }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# Update SMF: smf-n4iwf -> smf_n4iwf -> n4 -> "ipam" -> range + exclude[0]
patch_smf_ipam() {
  local file="$1" n4cidr="$2" excl="$3"
  awk -v CIDR="$n4cidr" -v EXC="$excl" '
    function indent(s,   i){ i=match(s,/[^[:space:]]/); return i?i-1:0 }
    function yaml_key(s,  t){ t=s; sub(/^[[:space:]]*/,"",t); sub(/:.*/,"",t); return t }
    BEGIN{in_top=0; in_mid=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_ex=0;}
    {
      line=$0; ind=indent(line);
      if (match(line,/^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*$/)) {
        key=yaml_key(line)
        if (!in_top && key=="smf-n4iwf"){in_top=1; ind_top=ind}
        else if (in_top && ind<=ind_top && key!="smf-n4iwf"){in_top=0; in_mid=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_ex=0}
        if (in_top){
          if (!in_mid && key=="smf_n4iwf"){in_mid=1; ind_mid=ind}
          else if (in_mid && ind<=ind_mid && key!="smf_n4iwf"){in_mid=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_ex=0}
        }
        if (in_mid){
          if (!in_n4 && key=="n4"){in_n4=1; ind_n4=ind}
          else if (in_n4 && ind<=ind_n4 && key!="n4"){in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_ex=0}
        }
      }

      if (in_mid && in_n4 && !in_ipam && line ~ /"ipam"[[:space:]]*:[[:space:]]*\{/){in_ipam=1}

      if (in_mid && in_n4 && in_ipam){
        if (!in_ranges && line ~ /"ipRanges"[[:space:]]*:[[:space:]]*\[/){in_ranges=1}
        else if (in_ranges && line ~ /"range"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"\s*,?$/){
          i=match(line,/[^[:space:]]/); pre=(i?substr(line,1,i-1):""); post=""
          if (line ~ /",[[:space:]]*$/) post=","
          print pre "\"range\": \"" CIDR "\"" post
          next
        } else if (in_ranges && line ~ /\]/){in_ranges=0}

        if (!in_ex && line ~ /"exclude"[[:space:]]*:[[:space:]]*\[/){
          in_ex=1; i=match(line,/[^[:space:]]/); exind=(i?substr(line,1,i-1):"") "  "
          print line; next
        } else if (in_ex && !wrote_ex && line ~ /^[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"\s*,?$/){
          trail=(line ~ /,[[:space:]]*$/)?",":""; print exind "\"" EXC "\"" trail
          wrote_ex=1; next
        } else if (in_ex && !wrote_ex && line ~ /^[[:space:]]*\]/){
          print exind "\"" EXC "\""
          print line
          in_ex=0; wrote_ex=1; next
        } else if (in_ex && line ~ /\]/){ in_ex=0 }

        if (in_ipam && !in_ranges && !in_ex && line ~ /^[[:space:]]*\}/){in_ipam=0}
      }

      print line
    }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# ---------- compute N4 and excludes ----------
if [[ -n "${N4_IN:-}" && "${N4_IN}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)\/([0-9]+)$ ]]; then
  base3="${BASH_REMATCH[1]}"; last="${BASH_REMATCH[2]}"; mask="${BASH_REMATCH[3]}"
  N4_RANGE="${base3}.${last}/${mask}"
  EXCL_UPF="${base3}.$((last+1))/32"
  EXCL_SMF="${base3}.$((last+2))/32"
else
  echo "[remote] ERROR: invalid N4_CIDR '${N4_IN}'"; exit 4
fi

# apply IPAM edits
patch_upf_ipam "$UPF" "${N4_RANGE}" "${EXCL_UPF}"
patch_smf_ipam "$SMF" "${N4_RANGE}" "${EXCL_SMF}"
echo "[remote] N4_RANGE=${N4_RANGE}  EXCL_UPF=${EXCL_UPF}  EXCL_SMF=${EXCL_SMF}"

# sanity prints (final)
awk '/# *NGC IP for external Communication/{p=NR+1} NR==p{print "[remote] AMF NGC line: " $0}' "$AMF" || true
grep -nE '^[[:space:]]*externalIP:' "$AMF" | head -1 | sed 's/^/[remote] /' || true
awk '/^ *intfConfig:/{f=1} f&&/^ *type:/{print "[remote] upf.type: "$0; f=0}' "$UPF" || true
awk '/^ *nguInterface:/{f=1} f&&/^ *pciAddress:/{print "[remote] upf.ngu pci: "$0; f=0}' "$UPF" || true
awk '/^ *n6Interface_0:/{f=1} f&&/^ *pciAddress:/{print "[remote] upf.n6  pci: "$0; f=0}' "$UPF" || true

echo "[remote] upf.exclude(final): $(awk '"'"'/"exclude"[[:space:]]*:[[:space:]]*\[/{ex=1;next} ex&&/"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/{gsub(/^ +/,"");print;ex=0}'"'"' "$UPF")"
echo "[remote] smf.exclude(final): $(awk '"'"'/"exclude"[[:space:]]*:[[:space:]]*\[/{ex=1;next} ex&&/"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/{gsub(/^ +/,"");print;ex=0}'"'"' "$SMF")"

grep -nE '"range"|exclude' "$UPF" "$SMF" | sed "s|${NF_ROOT}/||" || true
EOSH
# ---------- end of remote helpers ----------

# -------- iterate server lines --------
while IFS= read -r RAW; do
  [[ -z "$RAW" || "$RAW" =~ ^[[:space:]]*# ]] && continue

  # remove all whitespace to validate separators, but parse with original
  LINE_NO_WS="${RAW//[[:space:]]/}"
  IFS=':' read -r -a parts <<< "$LINE_NO_WS"
  n=${#parts[@]}

  # Parse original (preserve colons inside PCI)
  IFS=':' read -r NAME HOST OLD_BUILD MODE a b c d N4_CIDR AMF_IP <<< "$RAW"
  NAME="${NAME//[[:space:]]/}"; HOST="${HOST//[[:space:]]/}"; MODE="${MODE//[[:space:]]/}"
  if [[ -z "$NAME" || -z "$HOST" || -z "$MODE" || -z "$N4_CIDR" || -z "$AMF_IP" ]]; then
    echo "[nf_config] skip malformed line: $RAW"; continue
  fi

  # reconstruct N3/N6 from original tokens (support PCI with colons)
  # Expecting formats like:
  # VM:0000:08:00.0:0000:09:00.0:<N4>:<AMF>
  # SRIOV:ens2f0:ens2f1:<N4>:<AMF>
  read -r _ _ _ _ tail <<< "$RAW"
  tail="${tail#*:}"           # drop NAME
  tail="${tail#*:}"           # drop HOST
  tail="${tail#*:}"           # drop OLD_BUILD
  tail="${tail#*:}"           # drop MODE
  # Now tail starts at N3 ... we need to split at the last two fields (N4, AMF)
  AMF_IP="${tail##*:}"        # last
  pre_last="${tail%:*}"       # before last
  N4_CIDR="${pre_last##*:}"   # second last
  mid="${pre_last%:*}"        # up to N6
  # mid has N3 and N6 which may include colons; split from the left
  N3_VAL="${mid%%:*}"
  rest="${mid#*:}"
  N6_VAL="${rest}"

  echo "[nf_config][${HOST}] ▶ start"
  echo "[nf_config][${HOST}] parsed: MODE='${MODE}' N3='${N3_VAL}' N6='${N6_VAL}' N4='${N4_CIDR}' AMF='${AMF_IP}'"

  NF_ROOT="${NEW_BUILD_PATH%/}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"

  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${HOST}" \
    bash -se -- "${NF_ROOT}" "${MODE}" "${N3_VAL}" "${N6_VAL}" "${N4_CIDR}" "${AMF_IP}" "${CAP}" "${HOST}" "${VER}" <<<"$REMOTE_SCRIPT"

  echo "[nf_config][${HOST}] ◀ done"
done < "${SERVER_FILE}"

echo "[nf_config] All hosts processed."
