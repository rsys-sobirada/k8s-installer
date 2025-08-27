#!/usr/bin/env bash
# scripts/nf_config.sh — Configure NF YAMLs on CNs (robust exclude IP update)
# Required env: SERVER_FILE, SSH_KEY, NEW_BUILD_PATH, NEW_VERSION, DEPLOYMENT_TYPE
# Optional     : HOST_USER (default root), CN_DEPLOYMENT, N3_PCI, N6_PCI
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

# ----------------------------
# Run a robust remote script
# ----------------------------
run_remote() {
  # Args:
  #   $1   = SSH target (HOST)
  #   $2.. = NF_ROOT MODE N3 N6 N4 AMF CAP HOST_IP VER
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "${HOST_USER}@${1}" \
    bash -se -- "${@:2}" <<'EOSH'
set -euo pipefail
NF_ROOT="$1"; MODE_IN="$2"; N3_IN="$3"; N6_IN="$4"; N4_IN="$5"; AMF_IP="$6"; CAPACITY="$7"; HOST_IP="$8"; VER="$9"

UPF="${NF_ROOT}/upf-1-values.yaml"
SMF="${NF_ROOT}/smf-1-values.yaml"
AMF="${NF_ROOT}/amf-1-values.yaml"
GV="${NF_ROOT}/global-values.yaml"

echo "[remote] NF_ROOT=${NF_ROOT}"
for f in "$UPF" "$SMF" "$AMF" "$GV"; do [[ -f "$f" ]] || { echo "[remote] ERROR: missing $f"; exit 3; }; done

# Normalize CRLF (prevents awk/sed surprises)
sed -i 's/\r$//' "$UPF" "$SMF" "$AMF" "$GV"

# ---- simple scalar patcher
patch_key_scalar() { # file key value
  awk -v key="$2" -v val="$3" '
    !done && $0 ~ "^[[:space:]]*" key "[[:space:]]*:" {
      i=match($0,/[^[:space:]]/); ind=(i?substr($0,1,i-1):"");
      print ind key ": " val; done=1; next
    } { print }
  ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ---- capacity + FQDN
patch_key_scalar "$GV" "capacitySetup" "\"${CAPACITY}\""
patch_key_scalar "$GV" "ingressExtFQDN" "${HOST_IP}.nip.io"
if [[ "${CAPACITY}" == "LOW" ]]; then patch_key_scalar "$GV" "k8sCpuMgrStaticPolicyEnable" "false"; fi
echo "[remote] global-values.yaml updated."

# ---- bump image tag v1 -> VER in nf-services/scripts (top-level files only)
find "${NF_ROOT}" -maxdepth 1 -type f -name "*.yaml" -print0 | \
  xargs -0 sed -i -E 's/(image:[[:space:]]*"[^"]*:)v1(")/\1'"${VER}"'\2/g'
echo "[remote] replaced image tag v1 -> ${VER} in nf-services/scripts."

# ---- AMF externalIP (under comment and explicit key)
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

# ---- PCI helpers
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
# Ensure intfConfig.type matches mode if such block exists
if grep -qE '^ *intfConfig:' "$UPF"; then
  if [[ "${MODE_UP}" == "VM" ]]; then
    sed -i -e '/^ *intfConfig:/,/^ *upfsesscoresteps:/ { s/^\([[:space:]]*type:\).*/\1 "devPassthrough"/ }' "$UPF"
  else
    sed -i -e '/^ *intfConfig:/,/^ *upfsesscoresteps:/ { s/^\([[:space:]]*type:\).*/\1 "sriov"/ }' "$UPF"
  fi
fi

N3_PCI="$(resolve_pci "${N3_IN}")"
N6_PCI="$(resolve_pci "${N6_IN}")"

# Inject PCI (UPF nguInterface & n6Interface_0)
if [[ -n "${N3_PCI}" ]]; then
  sed -i -e '/^ *nguInterface:/,/^ *n6Interface_0:/ { s/^\([[:space:]]*pciAddress:\).*/\1 '"${N3_PCI}"'/ }' "$UPF"
fi
if [[ -n "${N6_PCI}" ]]; then
  sed -i -e '/^ *n6Interface_0:/,/^ *n6Interface_1:/ { s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/ }' "$UPF"
  sed -i -e '/^ *n6Interface_0:/,/^ *n9Interface:/    { s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/ }' "$UPF"
  sed -i -e '/^ *n6Interface_0:/,/^ *upfsesscoresteps:/ { s/^\([[:space:]]*pciAddress:\).*/\1 '"${N6_PCI}"'/ }' "$UPF"
fi

# ---- Compute N4_RANGE and excludes
if [[ -n "${N4_IN:-}" && "${N4_IN}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.([0-9]+)\/([0-9]+)$ ]]; then
  base3="${BASH_REMATCH[1]}"; last="${BASH_REMATCH[2]}"; mask="${BASH_REMATCH[3]}"
  N4_RANGE="${base3}.${last}/${mask}"
  EXCL_UPF="${base3}.$((last+1))/32"
  EXCL_SMF="${base3}.$((last+2))/32"
else
  echo "[remote] ERROR: invalid N4_CIDR '${N4_IN}'"; exit 4
fi

# ---- Indentation-aware UPF/SMF ipam patchers (overwrite first IPv4 in exclude; insert if empty)
patch_upf_ipam() {
  local file="$1" n4cidr="$2" excl="$3"
  awk -v CIDR="$n4cidr" -v EXC="$excl" '
    function indent(s,   i){ i=match(s,/[^[:space:]]/); return i?i-1:0 }
    function yaml_key(s,  t){ t=s; sub(/^[[:space:]]*/,"",t); sub(/:.*/,"",t); return t }
    BEGIN{in_upfsp=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_ex=0; }
    {
      line=$0; ind=indent(line);
      if (match(line,/^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*$/)) {
        key=yaml_key(line)
        if (!in_upfsp && key=="upfsp"){in_upfsp=1; ind_up=ind}
        else if (in_upfsp && ind<=ind_up && key!="upfsp"){in_upfsp=0; in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_ex=0}
        if (in_upfsp){
          if (!in_n4 && key=="n4"){in_n4=1; ind_n4=ind}
          else if (in_n4 && ind<=ind_n4 && key!="n4"){in_n4=0; in_ipam=0; in_ranges=0; in_ex=0; wrote_ex=0}
        }
      }
      if (in_upfsp && in_n4 && !in_ipam && line ~ /"ipam"[[:space:]]*:[[:space:]]*\{/){in_ipam=1}
      if (in_upfsp && in_n4 && in_ipam){
        if (!in_ranges && line ~ /"ipRanges"[[:space:]]*:[[:space:]]*\[/){in_ranges=1}
        else if (in_ranges && line ~ /"range"[[:space:]]*:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"\s*,?$/){
          i=match(line,/[^[:space:]]/); pre=(i?substr(line,1,i-1):""); post=(line ~ /",[[:space:]]*$/)?",":""
          print pre "\"range\": \"" CIDR "\"" post; next
        } else if (in_ranges && line ~ /\]/){in_ranges=0}
        if (!in_ex && line ~ /"exclude"[[:space:]]*:[[:space:]]*\[/){
          in_ex=1; i=match(line,/[^[:space:]]/); exind=(i?substr(line,1,i-1):"") "  "
          print line; next
        } else if (in_ex && !wrote_ex && line ~ /^[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"\s*,?$/){
          trail=(line ~ /,[[:space:]]*$/)?",":""; print exind "\"" EXC "\"" trail; wrote_ex=1; next
        } else if (in_ex && !wrote_ex && line ~ /^[[:space:]]*\]/){
          print exind "\"" EXC "\""; print line; in_ex=0; wrote_ex=1; next
        } else if (in_ex && line ~ /\]/){ in_ex=0 }
        if (in_ipam && !in_ranges && !in_ex && line ~ /^[[:space:]]*\}/){in_ipam=0}
      }
      print line
    }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

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
          i=match(line,/[^[:space:]]/); pre=(i?substr(line,1,i-1):""); post=(line ~ /",[[:space:]]*$/)?",":""
          print pre "\"range\": \"" CIDR "\"" post; next
        } else if (in_ranges && line ~ /\]/){in_ranges=0}
        if (!in_ex && line ~ /"exclude"[[:space:]]*:[[:space:]]*\[/){
          in_ex=1; i=match(line,/[^[:space:]]/); exind=(i?substr(line,1,i-1):"") "  "
          print line; next
        } else if (in_ex && !wrote_ex && line ~ /^[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"\s*,?$/){
          trail=(line ~ /,[[:space:]]*$/)?",":""; print exind "\"" EXC "\"" trail; wrote_ex=1; next
        } else if (in_ex && !wrote_ex && line ~ /^[[:space:]]*\]/){
          print exind "\"" EXC "\""; print line; in_ex=0; wrote_ex=1; next
        } else if (in_ex && line ~ /\]/){ in_ex=0 }
        if (in_ipam && !in_ranges && !in_ex && line ~ /^[[:space:]]*\}/){in_ipam=0}
      }
      print line
    }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# ---- Apply ipam updates with awk, verify, and (if needed) Python fallback
patch_upf_ipam "$UPF" "${N4_RANGE}" "${EXCL_UPF}"
patch_smf_ipam "$SMF" "${N4_RANGE}" "${EXCL_SMF}"

UPF_GOT="$(awk '/"exclude"[[:space:]]*:[[:space:]]*\[/{ex=1;next} ex&&/"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/{gsub(/^ +/,"");print;ex=0}' "$UPF")"
SMF_GOT="$(awk '/"exclude"[[:space:]]*:[[:space:]]*\[/{ex=1;next} ex&&/"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/{gsub(/^ +/,"");print;ex=0}' "$SMF")"

need_py=0
[[ "$UPF_GOT" != "\"${EXCL_UPF}\"" ]] && need_py=1
[[ "$SMF_GOT" != "\"${EXCL_SMF}\"" ]] && need_py=1

if (( need_py )) && command -v python3 >/dev/null 2>&1; then
  python3 - <<PY "$UPF" "$SMF" "$N4_RANGE" "$EXCL_UPF" "$EXCL_SMF"
import re, io, sys
upf, smf, n4, e_upf, e_smf = sys.argv[1:6]

def patch(txt, anchor_path_regex, new_range, new_excl):
    m = re.search(anchor_path_regex, txt, re.S)
    if not m: return txt, False
    start = m.end()

    # range
    r1 = re.search(r'"ipRanges"[ \t]*:[ \t]*\[', txt[start:], re.S)
    if r1:
        pos = start + r1.end()
        txt = txt[:pos] + re.sub(r'(?m)^([ \t]*"range":[ \t]*")[0-9]+(?:\.[0-9]+){3}/[0-9]+(".*$)',
                                  r'\g<1>'+new_range+r'\2', txt[pos:], count=1)

    # exclude
    r2 = re.search(r'"exclude"[ \t]*:[ \t]*\[\n', txt[start:], re.S)
    if r2:
        pos = start + r2.end()
        r3 = re.search(r'\n[ \t]*\]', txt[pos:])
        if r3:
            body = txt[pos:pos+r3.start()]
            # replace first IPv4, else insert
            def replace_first(m):
                replace_first.done = True
                return m.group(1) + '"' + new_excl + '"' + m.group(3)
            replace_first.done = False
            body2 = re.sub(r'(?m)^([ \t]*)"([0-9]+(?:\.[0-9]+){3}/[0-9]+)"([ \t]*,?)',
                           replace_first, body, count=1)
            if not replace_first.done:
                i = re.search(r'[ \t]*', body).group(0)
                body2 = i + '  "' + new_excl + '"\n' + body
            txt = txt[:pos] + body2 + txt[pos+r3.start():]
    return txt, True

with io.open(upf,'r',encoding='utf-8',errors='ignore') as f: S=f.read()
S2,_ = patch(S, r'upfsp:[\s\S]*?n4:[\s\S]*?"ipam"[ \t]*:[ \t]*\{', n4, e_upf)
io.open(upf,'w',encoding='utf-8').write(S2)

with io.open(smf,'r',encoding='utf-8',errors='ignore') as f: S=f.read()
S2,_ = patch(S, r'smf-n4iwf:[\s\S]*?smf_n4iwf:[\s\S]*?n4:[\s\S]*?"ipam"[ \t]*:[ \t]*\{', n4, e_smf)
io.open(smf,'w',encoding='utf-8').write(S2)
PY
fi

# ---- final sanity prints
echo "[remote] N4_RANGE=${N4_RANGE}  EXCL_UPF=${EXCL_UPF}  EXCL_SMF=${EXCL_SMF}"
awk '/# *NGC IP for external Communication/{p=NR+1} NR==p{print "[remote] AMF NGC line: " $0}' "$AMF" || true
grep -nE '^[[:space:]]*externalIP:' "$AMF" | head -1 | sed 's/^/[remote] /' || true
awk '/^ *intfConfig:/{f=1} f&&/^ *type:/{print "[remote] upf.type: "$0; f=0}' "$UPF" || true
awk '/^ *nguInterface:/{f=1} f&&/^ *pciAddress:/{print "[remote] upf.ngu pci: "$0; f=0}' "$UPF" || true
awk '/^ *n6Interface_0:/{f=1} f&&/^ *pciAddress:/{print "[remote] upf.n6  pci: "$0; f=0}' "$UPF" || true

echo "[remote] upf.exclude(final): $(awk '"'"'/"exclude"[[:space:]]*:[[:space:]]*\[/{ex=1;next} ex&&/"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/{gsub(/^ +/,"");print;ex=0}'"'"' "$UPF")"
echo "[remote] smf.exclude(final): $(awk '"'"'/"exclude"[[:space:]]*:[[:space:]]*\[/{ex=1;next} ex&&/"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+"/{gsub(/^ +/,"");print;ex=0}'"'"' "$SMF")"

# helpful grep of both files
grep -nE '"ipam"| "ipRanges"| "range"| "exclude"' "$UPF" "$SMF" | sed "s|${NF_ROOT}/||" || true
EOSH
}

# ----------------------------
# Iterate servers (robust parser for colon-filled PCI fields)
# ----------------------------
while IFS= read -r RAW || [[ -n "${RAW:-}" ]]; do
  [[ -z "$RAW" || "$RAW" =~ ^[[:space:]]*# ]] && continue

  # Use awk to safely split even when N3/N6 contain colons
  parsed_line="$(
    awk -F: '
      BEGIN{OFS="\t"}
      {
        name=$1; host=$2; build=$3; mode=$4
        amf=$NF
        n4=$(NF-1)
        # tokens between mode and n4/amf:
        mid_start=5; mid_end=NF-2; cnt=mid_end-mid_start+1
        if (cnt<=0){ next }
        if (mode ~ /VM|vm/ && cnt>=6){
          n3=$5 ":" $6 ":" $7
          n6=$8 ":" $9 ":" $10
        } else if (cnt==2){
          n3=$5; n6=$6
        } else {
          # fallback: split middle tokens in half
          half=int(cnt/2)
          n3=$5; for(i=6;i<5+half;i++){ n3=n3 ":" $i }
          n6=$(5+half); for(i=6+half;i<=mid_end;i++){ n6=n6 ":" $i }
        }
        print name,host,build,mode,n3,n6,n4,amf
      }' <<<"$RAW"
  )" || true

  if [[ -z "${parsed_line:-}" ]]; then
    echo "[nf_config] skip malformed line: $RAW"
    continue
  fi

  IFS=$'\t' read -r NAME HOST REMOTE_BUILD MODE N3_VAL N6_VAL N4_CIDR AMF_IP <<< "$parsed_line"

  echo "[nf_config][${HOST}] ▶ start"
  echo "[nf_config][${HOST}] parsed: MODE='${MODE}' N3='${N3_VAL}' N6='${N6_VAL}' N4='${N4_CIDR}' AMF='${AMF_IP}'"

  NF_ROOT="${NEW_BUILD_PATH%/}/TRILLIUM_5GCN_CNF_REL_${VER}/nf-services/scripts"

  run_remote "${HOST}" "${NF_ROOT}" "${MODE}" "${N3_VAL}" "${N6_VAL}" "${N4_CIDR}" "${AMF_IP}" "${CAP}" "${HOST}" "${VER}"

  echo "[nf_config][${HOST}] ◀ done"
done < "${SERVER_FILE}"

echo "[nf_config] All hosts processed."
