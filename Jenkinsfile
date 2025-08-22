// ================== Parameters (Active Choices, ordered as requested) ==================
properties([
  parameters([
    // 1) Deployment type
    choice(
      name: 'DEPLOYMENT_TYPE',
      choices: 'Low\nMedium\nHigh',
      description: 'Deployment type'
    ),

    // 2) Install mode (controls OLD_BUILD_PATH visibility)
    choice(
      name: 'INSTALL_MODE',
      choices: 'Upgrade_with_cluster_reset\nUpgrade_without_cluster_reset\nFresh_installation',
      description: 'Select installation mode'
    ),

    // 3) OLD_BUILD_PATH shown only for Upgrade_* modes
    [
      $class: 'DynamicReferenceParameter',
      name: 'OLD_BUILD_PATH_UI',
      description: 'Base dir of OLD_VERSION (shown only for Upgrade modes)',
      referencedParameters: 'INSTALL_MODE',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [
          script: '''
def mode = (INSTALL_MODE ?: "").toString()
if (mode == 'Fresh_installation') return ""
return """<input class='setting-input' name='value' type='text' value='/home/labadmin'/>"""
''',
          sandbox: true,
          classpath: []
        ],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    // 4) New build path
    string(name: 'NEW_BUILD_PATH',
           defaultValue: '/home/labadmin',
           description: 'Base dir to place NEW_VERSION (and extract)'),

    // 5) New version
    choice(name: 'NEW_VERSION',
           choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2',
           description: 'Target bundle (may have suffix, e.g., 6.3.0_EA2)'),

    // 6) Old version
    choice(name: 'OLD_VERSION',
           choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2',
           description: 'Existing bundle (used if upgrading)'),

    // 7) Fetch toggle
    booleanParam(name: 'FETCH_BUILD',
           defaultValue: true,
           description: 'Fetch NEW_VERSION from build host to CN servers'),

    // 8) Host (visible only if FETCH_BUILD truthy)
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_HOST',
      description: 'Build repo host',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [
          script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="172.26.2.96">172.26.2.96</option>
           <option value="172.26.2.95">172.26.2.95</option>
         </select>"""
''',
          sandbox: true,
          classpath: []
        ],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    // 9) User (visible only if FETCH_BUILD truthy)
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_USER',
      description: 'Build repo user',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [
          script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="sobirada">sobirada</option>
           <option value="labadmin">labadmin</option>
         </select>"""
''',
          sandbox: true,
          classpath: []
        ],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    // 10) Base path (visible only if FETCH_BUILD truthy)
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_BASE',
      description: 'Path on build host containing the tar.gz files',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [
          script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<select class='setting-input' name='value'>
           <option value="/CNBuild/6.3.0_EA2">/CNBuild/6.3.0_EA2</option>
           <option value="/CNBuild/6.3.0">/CNBuild/6.3.0</option>
           <option value="/CNBuild/6.3.0_EA1">/CNBuild/6.3.0_EA1</option>
         </select>"""
''',
          sandbox: true,
          classpath: []
        ],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    // 11) Password (Active Choices; conditional; visually masked)
    [
      $class: 'DynamicReferenceParameter',
      name: 'BUILD_SRC_PASS',
      description: 'Build host password (for SCP/SSH from build repo)',
      referencedParameters: 'FETCH_BUILD',
      choiceType: 'ET_FORMATTED_HTML',
      omitValueField: true,
      script: [
        $class: 'GroovyScript',
        script: [
          script: '''
def fb = (FETCH_BUILD ?: "").toString().trim().toLowerCase()
def enabled = ['true','on','1','yes','y'].contains(fb)
if (!enabled) return ""
return """<input type='password' class='setting-input' name='value' value=''/>"""
''',
          sandbox: true,
          classpath: []
        ],
        fallbackScript: [ script: 'return ""', sandbox: true, classpath: [] ]
      ]
    ],

    // 12) Alias IP/CIDR
    string(name: 'INSTALL_IP_ADDR',
           defaultValue: '10.10.10.20/24',
           description: 'Alias IP/CIDR to plumb on CN servers'),

    // -------- OPTIONAL bootstrap password (used by bootstrap_keys.sh) --------
    password(
      name: 'CN_BOOTSTRAP_PASS',
      defaultValue: '',
      description: 'One-time CN root password (used by bootstrap_keys.sh when password SSH is needed)'
    )
  ])
])

// =================================== Pipeline ===================================
pipeline {
  agent any
  options { timestamps(); disableConcurrentBuilds() }

  environment {
    SERVER_FILE = 'server_pci_map.txt'
    SSH_KEY     = '/var/lib/jenkins/.ssh/jenkins_key'   // CN servers use this key (root)
    K8S_VER     = '1.31.4'
    EXTRACT_BUILD_TARBALLS = 'false'                    // fetch: do NOT untar
    INSTALL_IP_ADDR  = '10.10.10.20/24'                 // default; overridden by param
  }

  stages {
    stage('Checkout') {
      steps { checkout scm }
    }

    stage('Validate inputs') {
      steps {
        script {
          if (params.INSTALL_MODE != 'Fresh_installation' && !params.OLD_BUILD_PATH_UI?.trim()) {
            error "OLD_BUILD_PATH is required for ${params.INSTALL_MODE}"
          }
        }
      }
    }

    // ───────────────────────────── PRE-BOOTSTRAP (Fresh only) ─────────────────────────────
    stage('Pre-bootstrap keys (Fresh only)') {
      when { expression { return params.INSTALL_MODE == 'Fresh_installation' } }
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

# Inputs
: "${SERVER_FILE:?missing}"
: "${SSH_KEY:?missing}"
: "${INSTALL_IP_ADDR:?missing}"        # e.g., 10.10.10.20/24
: "${CN_BOOTSTRAP_PASS:=root123}"

# Clean CRLF & ensure executable locally (source of truth)
sed -i 's/\\r$//' scripts/bootstrap_keys.sh || true
chmod +x scripts/bootstrap_keys.sh

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=8"
SCRIPT_LOCAL="scripts/bootstrap_keys.sh"
SCRIPT_REMOTE="/root/bootstrap_keys.sh"
ALIAS_CIDR="${INSTALL_IP_ADDR}"
ALIAS_IP="${INSTALL_IP_ADDR%%/*}"
LOCAL_SHA="$(sha256sum "${SCRIPT_LOCAL}" | awk '{print $1}')"

echo "[bootstrap][runner] Hosts: $(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){n=split($0,a,":"); print a[2]} else {print $1} }' "${SERVER_FILE}" | xargs)"
echo "[bootstrap][runner] Alias IP: ${ALIAS_IP}  (from ${ALIAS_CIDR})"

# Parse host list
mapfile -t HOSTS < <(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){n=split($0,a,":"); print a[2]} else {print $1} }' "${SERVER_FILE}")

ship_and_run() {
  local HOST="$1"

  echo ""
  echo "─── Host ${HOST} ───────────────────────────────────────"

  # 0) Ensure alias IP exists on CN **before** bootstrap
  ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" bash -s -- "${ALIAS_CIDR}" <<'RS' || true
set -euo pipefail
CIDR="$1"

is_present(){ ip -4 addr show | awk '/inet /{print $2}' | grep -qx "$CIDR"; }
if is_present; then
  echo "[IP] Present: ${CIDR}"
  exit 0
fi

declare -a CAND=()
DEF_IF=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}' || true)
[[ -n "${DEF_IF:-}" ]] && CAND+=("$DEF_IF")
while IFS= read -r ifc; do CAND+=("$ifc"); done < <(
  ip -o link | awk -F': ' '{print $2}' \
  | grep -E '^(en|eth|ens|eno|em|bond|br)[0-9A-Za-z._-]+' \
  | grep -Ev '(^lo$|docker|podman|cni|flannel|cilium|calico|weave|veth|tun|tap|virbr|wg)' \
  | sort -u
)

for IF in "${CAND[@]}"; do
  [[ -z "$IF" ]] && continue
  echo "[IP] Trying ${CIDR} on iface ${IF}..."
  ip link set dev "$IF" up || true
  if ip addr replace "$CIDR" dev "$IF" 2>"/tmp/ip_err_${IF}.log"; then
    if ip -4 addr show dev "$IF" | grep -q "$CIDR"; then
      echo "[IP] OK on ${IF}"
      exit 0
    fi
  fi
  echo "[IP] Failed on ${IF}: $(tr -d '\\n' </tmp/ip_err_${IF}.log)" || true
done

echo "[IP] ERROR: Could not plumb ${CIDR} on any iface."
exit 2
RS

  # 1) Copy script (base64) or fallback with sshpass if key SSH isn't ready
  if ! ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" true 2>/dev/null; then
    echo "[ship] Key SSH not ready → using sshpass for initial copy to ${HOST}"
    if ! command -v sshpass >/dev/null 2>&1; then
      echo "[ship] Installing sshpass on runner..."
      sudo -E apt-get install -yq --no-install-recommends --no-upgrade sshpass
    fi
    sshpass -p "${CN_BOOTSTRAP_PASS}" scp -q -o StrictHostKeyChecking=no "${SCRIPT_LOCAL}" "root@${HOST}:${SCRIPT_REMOTE}.tmp"
    sshpass -p "${CN_BOOTSTRAP_PASS}" ssh -o StrictHostKeyChecking=no "root@${HOST}" bash -lc "
      sed -i 's/\\r\\$//' ${SCRIPT_REMOTE}.tmp || true
      mv -f ${SCRIPT_REMOTE}.tmp ${SCRIPT_REMOTE}
      chmod +x ${SCRIPT_REMOTE}
    "
  else
    base64 -w0 "${SCRIPT_LOCAL}" | ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" "base64 -d > '${SCRIPT_REMOTE}.tmp'"
    ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" bash -lc "
      sed -i 's/\\r\\$//' ${SCRIPT_REMOTE}.tmp || true
      mv -f ${SCRIPT_REMOTE}.tmp ${SCRIPT_REMOTE}
      chmod +x ${SCRIPT_REMOTE}
    "
  fi

  # 2) Verify checksum
  REMOTE_SHA="$(ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" sha256sum "${SCRIPT_REMOTE}" 2>/dev/null | awk '{print $1}')"
  if [[ -z "${REMOTE_SHA:-}" || "${REMOTE_SHA}" != "${LOCAL_SHA}" ]]; then
    echo "❌ Checksum mismatch on ${HOST} (local=${LOCAL_SHA} remote=${REMOTE_SHA:-<none>})."
    exit 2
  fi
  echo "✅ Script integrity OK on ${HOST}"

  # 3) Run the script ON the CN (ensures sshpass on CN, keypair, copies to host+alias)
  echo "[run] ${SCRIPT_REMOTE} --host ${HOST} --alias-ip ${ALIAS_IP} --pass '******' --force"
  ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" \
    "${SCRIPT_REMOTE} --host ${HOST} --alias-ip ${ALIAS_IP} --pass '${CN_BOOTSTRAP_PASS}' --force"
}

rc=0
for H in "${HOSTS[@]}"; do
  if ! ship_and_run "$H"; then rc=1; fi
done
exit $rc
'''
        }
      }
    }

    stage('Reset &/or Fetch (parallel)') {
      parallel {
        stage('Cluster reset (auto from INSTALL_MODE)') {
          when { expression { return params.INSTALL_MODE == 'Upgrade_with_cluster_reset' } }
          steps {
            timeout(time: 15, unit: 'MINUTES', activity: true) {
              sh '''
                set -eu
                echo ">>> Cluster reset starting (INSTALL_MODE=Upgrade_with_cluster_reset)"
                sed -i 's/\r$//' scripts/cluster_reset.sh || true
                chmod +x scripts/cluster_reset.sh
                env \
                  CLUSTER_RESET=true \
                  OLD_VERSION="${OLD_VERSION}" \
                  OLD_BUILD_PATH="${OLD_BUILD_PATH_UI}" \
                  K8S_VER="${K8S_VER}" \
                  KSPRAY_DIR="kubespray-2.27.0" \
                  RESET_YML_WS="$WORKSPACE/reset.yml" \
                  SSH_KEY="${SSH_KEY}" \
                  SERVER_FILE="${SERVER_FILE}" \
                  REQ_WAIT_SECS="360" \
                  RETRY_COUNT="3" \
                  RETRY_DELAY_SECS="10" \
                bash -euo pipefail scripts/cluster_reset.sh
              '''
            }
          }
        }

        stage('Fetch build to CN (optional)') {
          when { expression { return params.FETCH_BUILD } }
          steps {
            timeout(time: 15, unit: 'MINUTES', activity: true) {
              sh '''
                set -eu
                sed -i 's/\r$//' scripts/fetch_build.sh || true
                chmod +x scripts/fetch_build.sh

                # We ONLY use password auth for the BUILD host.
                if [ -n "${BUILD_SRC_PASS:-}" ]; then
                  if ! command -v sshpass >/dev/null 2>&1; then
                    echo "ERROR: sshpass is required on this agent for password-based SCP/SSH to BUILD_SRC_HOST." >&2
                    exit 2
                  fi
                fi

                echo "Targets from ${SERVER_FILE}:"
                awk 'NF && $1 !~ /^#/' "${SERVER_FILE}" || true

                NEW_VERSION="${NEW_VERSION}" \
                NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
                SERVER_FILE="${SERVER_FILE}" \
                BUILD_SRC_HOST="${BUILD_SRC_HOST}" \
                BUILD_SRC_USER="${BUILD_SRC_USER}" \
                BUILD_SRC_BASE="${BUILD_SRC_BASE}" \
                BUILD_SRC_PASS="${BUILD_SRC_PASS:-}" \
                CN_SSH_KEY="${SSH_KEY}" \
                EXTRACT_BUILD_TARBALLS="${EXTRACT_BUILD_TARBALLS}" \
                bash -euo pipefail scripts/fetch_build.sh
              '''
            }
          }
        }
      }
    }

    // ───────────────────────────── CLUSTER INSTALL (with auto-retry) ─────────────────────────────
    stage('Cluster install') {
      steps {
        timeout(time: 15, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail
echo ">>> Cluster install starting (mode: ${INSTALL_MODE})"

# hygiene
sed -i 's/\\r$//' scripts/cluster_install.sh || true
chmod +x scripts/cluster_install.sh
sed -i 's/\\r$//' scripts/bootstrap_keys.sh || true
chmod +x scripts/bootstrap_keys.sh

SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=8"
SCRIPT_LOCAL="scripts/bootstrap_keys.sh"
SCRIPT_REMOTE="/root/bootstrap_keys.sh"
ALIAS_CIDR="${INSTALL_IP_ADDR}"
ALIAS_IP="${INSTALL_IP_ADDR%%/*}"
LOCAL_SHA="$(sha256sum "${SCRIPT_LOCAL}" | awk '{print $1}')"

ship_and_run_bootstrap() {
  # (re)ship and (re)run bootstrap_keys.sh on all CNs; used on retry condition
  : "${SERVER_FILE:?missing}"
  : "${SSH_KEY:?missing}"
  : "${CN_BOOTSTRAP_PASS:=root123}"

  # Parse host list
  mapfile -t HOSTS < <(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){n=split($0,a,":"); print a[2]} else {print $1} }' "${SERVER_FILE}")

  for HOST in "${HOSTS[@]}"; do
    echo ""
    echo "─── (retry) Host ${HOST} ───────────────────────────────────────"

    # Ensure alias IP before re-bootstrap
    ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" bash -s -- "${ALIAS_CIDR}" <<'RS' || true
set -euo pipefail
CIDR="$1"
is_present(){ ip -4 addr show | awk '/inet /{print $2}' | grep -qx "$CIDR"; }
if is_present; then echo "[IP] Present: ${CIDR}"; exit 0; fi
DEF_IF=$(ip route 2>/dev/null | awk '/^default/{print $5; exit}' || true)
CAND=()
[[ -n "${DEF_IF:-}" ]] && CAND+=("$DEF_IF")
while IFS= read -r ifc; do CAND+=("$ifc"); done < <(
  ip -o link | awk -F': ' '{print $2}' \
  | grep -E '^(en|eth|ens|eno|em|bond|br)' \
  | grep -Ev '(^lo$|docker|podman|cni|flannel|cilium|calico|weave|veth|tun|tap|virbr|wg)' \
  | sort -u
)
for IF in "${CAND[@]}"; do
  [[ -z "$IF" ]] && continue
  echo "[IP] Trying ${CIDR} on iface ${IF}..."
  ip link set dev "$IF" up || true
  if ip addr replace "$CIDR" dev "$IF" 2>/dev/null; then
    if ip -4 addr show dev "$IF" | grep -q "$CIDR"; then echo "[IP] OK on ${IF}"; exit 0; fi
  fi
done
echo "[IP] WARN: Could not plumb ${CIDR} (continuing)."
exit 0
RS

    if ! ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" true 2>/dev/null; then
      if ! command -v sshpass >/dev/null 2>&1; then
        echo "[ship] Installing sshpass on runner..."
        sudo -E apt-get install -yq --no-install-recommends --no-upgrade sshpass
      fi
      sshpass -p "${CN_BOOTSTRAP_PASS}" scp -q -o StrictHostKeyChecking=no "${SCRIPT_LOCAL}" "root@${HOST}:${SCRIPT_REMOTE}.tmp"
      sshpass -p "${CN_BOOTSTRAP_PASS}" ssh -o StrictHostKeyChecking=no "root@${HOST}" bash -lc "
        sed -i 's/\\r\\$//' ${SCRIPT_REMOTE}.tmp || true
        mv -f ${SCRIPT_REMOTE}.tmp ${SCRIPT_REMOTE}
        chmod +x ${SCRIPT_REMOTE}
      "
    else
      base64 -w0 "${SCRIPT_LOCAL}" | ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" "base64 -d > '${SCRIPT_REMOTE}.tmp'"
      ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" bash -lc "
        sed -i 's/\\r\\$//' ${SCRIPT_REMOTE}.tmp || true
        mv -f ${SCRIPT_REMOTE}.tmp ${SCRIPT_REMOTE}
        chmod +x ${SCRIPT_REMOTE}
      "
    fi

    REMOTE_SHA="$(ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" sha256sum "${SCRIPT_REMOTE}" 2>/dev/null | awk '{print $1}')"
    if [[ -z "${REMOTE_SHA:-}" || "${REMOTE_SHA}" != "${LOCAL_SHA}" ]]; then
      echo "❌ Checksum mismatch on ${HOST} during retry."
      return 2
    fi

    ssh ${SSH_OPTS} -i "${SSH_KEY}" "root@${HOST}" \
      "${SCRIPT_REMOTE} --host ${HOST} --alias-ip ${ALIAS_IP} --pass '${CN_BOOTSTRAP_PASS}' --force"
  done
}

run_install() {
  echo "[jenkins] invoking cluster_install.sh ..."
  set +e
  OUTPUT="$(
    env \
      NEW_VERSION="${NEW_VERSION}" \
      NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
      K8S_VER="${K8S_VER}" \
      KSPRAY_DIR="kubespray-2.27.0" \
      INSTALL_SERVER_FILE="${SERVER_FILE}" \
      INSTALL_IP_ADDR="${INSTALL_IP_ADDR}" \
      SSH_KEY="${SSH_KEY}" \
      INSTALL_MODE="${INSTALL_MODE}" \
      INSTALL_RETRY_COUNT="3" \
      INSTALL_RETRY_DELAY_SECS="20" \
      BUILD_WAIT_SECS="300" \
    bash -euo pipefail scripts/cluster_install.sh
  )"
  RC=$?
  set -e
  echo "${OUTPUT}"
  return ${RC}
}

should_retry_bootstrap() {
  # Retry on SSH-denied regardless of INSTALL_MODE
  local rc="$1" out="$2"
  if [[ "${rc}" -eq 42 ]]; then return 0; fi
  if echo "${out}" | grep -qE 'ANSIBLE_SSH_DENIED|Permission denied \\(publickey,password\\)'; then return 0; fi
  return 1
}

# First attempt
set +e
OUT1="$(run_install)"
RC1=$?
set -e

if should_retry_bootstrap "${RC1}" "${OUT1}"; then
  echo "[jenkins] SSH permission issue detected → (re)bootstrapping keys on CN(s) then retrying once."
  ship_and_run_bootstrap

  # Second attempt
  set +e
  OUT2="$(run_install)"
  RC2=$?
  set -e
  echo "${OUT2}"
  exit ${RC2}
fi

exit ${RC1}
'''
        }
      }
    }

    // ---------- Cluster health check ----------
    stage('Cluster health check') {
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { n=split($0,a,":"); print a[2]; exit } else { print $1; exit } }' "${SERVER_FILE}")"
if [[ -z "${HOST}" ]]; then
  echo "[cluster-health] ERROR: could not parse host from ${SERVER_FILE}" >&2
  exit 2
fi
echo "[cluster-health] Using host ${HOST} for kubectl checks"

ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail
  check() {
    local notok=0
    if ! command -v kubectl >/dev/null 2>&1; then
      echo "[cluster-health] kubectl not found on CN host; cluster not ready yet."
      return 1
    fi
    while read -r ns name ready status rest; do
      x="${ready%%/*}"; y="${ready##*/}"
      if [[ "$status" != "Running" || "$x" != "$y" ]]; then
        echo "[cluster-health] $ns/$name not healthy (READY=$ready STATUS=$status)"
        notok=1
      fi
    done < <(kubectl get pods -A --no-headers || true)
    return $notok
  }

  if check; then
    echo "[cluster-health] ✅ All pods Running & Ready."
    exit 0
  fi

  echo "[cluster-health] Pods not healthy or kubectl missing, waiting 300s and retrying..."
  sleep 300

  if check; then
    echo "[cluster-health] ✅ Healthy after retry."
    exit 0
  else
    echo "[cluster-health] ❌ Still not healthy."
    kubectl get pods -A || true
    exit 1
  fi
'
'''
        }
      }
    }

    // ---------- PS config & install ----------
    stage('PS config & install') {
      steps {
        timeout(time: 30, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

sed -i 's/\\r$//' scripts/ps_config.sh || true
chmod +x scripts/ps_config.sh

env \
  SERVER_FILE="${SERVER_FILE}" \
  SSH_KEY="${SSH_KEY}" \
  NEW_VERSION="${NEW_VERSION}" \
  NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
  INSTALL_IP_ADDR="${INSTALL_IP_ADDR}" \
  DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE}" \
bash -euo pipefail scripts/ps_config.sh
'''
        }
      }
    }

    // ---------- PS health check ----------
    stage('PS health check') {
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { n=split($0,a,":"); print a[2]; exit } else { print $1; exit } }' "${SERVER_FILE}")"
if [[ -z "${HOST}" ]]; then
  echo "[ps-health] ERROR: could not parse host from ${SERVER_FILE}" >&2
  exit 2
fi
echo "[ps-health] Using host ${HOST} for kubectl checks"

ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail
  check() {
    local notok=0
    if ! command -v kubectl >/dev/null 2>&1; then
      echo "[ps-health] kubectl not found on CN host; cluster not ready yet."
      return 1
    fi
    while read -r ns name ready status rest; do
      x="${ready%%/*}"; y="${ready##*/}"
      if [[ "$status" != "Running" || "$x" != "$y" ]]; then
        echo "[ps-health] $ns/$name not healthy (READY=$ready STATUS=$status)"
        notok=1
      fi
    done < <(kubectl get pods -A --no-headers || true)
    return $notok
  }

  if check; then
    echo "[ps-health] ✅ All pods Running & Ready."
    exit 0
  fi

  echo "[ps-health] Pods not healthy or kubectl missing, waiting 300s and retrying..."
  sleep 300

  if check; then
    echo "[ps-health] ✅ Healthy after retry."
    exit 0
  else
    echo "[ps-health] ❌ Still not healthy."
    kubectl get pods -A || true
    exit 1
  fi
'
'''
        }
      }
    }

    // (Add CS/NF stages next using the same pattern.)
  }

  post {
    always {
      archiveArtifacts artifacts: '**/*.log', allowEmptyArchive: true
    }
  }
}
