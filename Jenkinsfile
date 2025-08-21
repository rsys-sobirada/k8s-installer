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
    string(
      name: 'NEW_BUILD_PATH',
      defaultValue: '/home/labadmin',
      description: 'Base dir to place NEW_VERSION (and extract)'
    ),

    // 5) New version
    choice(
      name: 'NEW_VERSION',
      choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2',
      description: 'Target bundle (may have suffix, e.g., 6.3.0_EA2)'
    ),

    // 6) Old version
    choice(
      name: 'OLD_VERSION',
      choices: '6.2.0_EA6\n6.3.0\n6.3.0_EA1\n6.3.0_EA2',
      description: 'Existing bundle (used if upgrading)'
    ),

    // 7) Fetch toggle
    booleanParam(
      name: 'FETCH_BUILD',
      defaultValue: true,
      description: 'Fetch NEW_VERSION from build host to CN servers'
    ),

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
    string(
      name: 'INSTALL_IP_ADDR',
      defaultValue: '10.10.10.20/24',
      description: 'Alias IP/CIDR to plumb on CN servers'
    ),

    // -------- OPTIONAL bootstrap controls (appended; does not disturb your order) --------
    booleanParam(
      name: 'CN_BOOTSTRAP',
      defaultValue: false,
      description: 'If true, push Jenkins SSH key to CN hosts before fetch (needs CN_BOOTSTRAP_PASS)'
    ),
    password(
      name: 'CN_BOOTSTRAP_PASS',
      defaultValue: '',
      description: 'One-time CN root password, used only when CN_BOOTSTRAP=true'
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

    // ---------- Ensure alias IP first, install sshpass on CN, then SSH bootstrap ----------
    stage('CN SSH bootstrap (optional)') {
      when {
        expression { return params.CN_BOOTSTRAP || params.INSTALL_MODE == 'Fresh_installation' }
      }
      steps {
        timeout(time: 15, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail

: "${SERVER_FILE:?missing SERVER_FILE}"
: "${SSH_KEY:?missing SSH_KEY}"
: "${INSTALL_IP_ADDR:?missing INSTALL_IP_ADDR}"
ALIAS_IP="${INSTALL_IP_ADDR%%/*}"
CN_BOOTSTRAP_PASS="${CN_BOOTSTRAP_PASS:-root123}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SVC=l
export UCF_FORCE_CONFFOLD=1

# ---------- remote snippet: ensure alias IP ----------
read -r -d '' ENSURE_IP_SNIPPET <<'RS' || true
set -euo pipefail
IP_CIDR="$1"; FORCE_IFACE="${2-}"
is_present(){ ip -4 addr show | awk "/inet /{print \\$2}" | grep -qx "$IP_CIDR"; }
echo "[IP] Ensuring ${IP_CIDR}"
if is_present; then echo "[IP] Present: ${IP_CIDR}"; exit 0; fi
declare -a CAND=()
[[ -n "$FORCE_IFACE" ]] && CAND+=("$FORCE_IFACE")
DEF_IF=$(ip route 2>/dev/null | awk "/^default/{print \\$5; exit}" || true)
[[ -n "${DEF_IF:-}" ]] && CAND+=("$DEF_IF")
while IFS= read -r ifc; do CAND+=("$ifc"); done < <(
  ip -o link | awk -F': ' '{print $2}' \
    | grep -E "^(en|eth|ens|eno|em|bond|br)[0-9A-Za-z._-]+" \
    | grep -Ev "(^lo$|docker|podman|cni|flannel|cilium|calico|weave|veth|tun|tap|virbr|wg)" \
    | sort -u
)
for IF in "${CAND[@]}"; do
  [[ -z "$IF" ]] && continue
  echo "[IP] Trying ${IP_CIDR} on iface ${IF}..."
  ip link set dev "$IF" up || true
  if ip addr replace "$IP_CIDR" dev "$IF" 2>"/tmp/ip_err_${IF}.log"; then
    ip -4 addr show dev "$IF" | grep -q "$IP_CIDR" && { echo "[IP] OK on ${IF}"; exit 0; }
  fi
  echo "[IP] Failed on ${IF}: $(tr -d '\\n' </tmp/ip_err_${IF}.log)" || true
done
echo "[IP] ERROR: Could not plumb ${IP_CIDR} on any iface. Candidates tried: ${CAND[*]}"; exit 2
RS

# ---------- remote snippet: fix sshd to listen on alias + allow bootstrap auth ----------
read -r -d '' FIX_SSHD_SNIPPET <<'RS' || true
set -euo pipefail
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-listen-all.conf <<'EOT'
ListenAddress 0.0.0.0
EOT
cat >/etc/ssh/sshd_config.d/99-bootstrap-auth.conf <<'EOT'
PermitRootLogin yes
PasswordAuthentication yes
EOT
sshd -t && (systemctl restart sshd || service ssh restart || true)
ss -ltnp | awk '$4 ~ /:22$/ {print "[sshd] listening on",$4}'
RS

# ---------- runner helpers ----------
ensure_sshpass_runner() {
  if command -v sshpass >/dev/null 2>&1; then return 0; fi
  echo "[bootstrap] sshpass not found on runner; installing (no upgrades/no popups)..."
  if command -v apt-get >/dev/null 2>&1; then
    sudo -E apt-get install -yq --no-install-recommends --no-upgrade sshpass
  elif command -v yum >/dev/null 2>&1; then
    sudo -E yum install -y sshpass
  else
    echo "[bootstrap] ❌ Unknown package manager on runner"; exit 1
  fi
}

ensure_keypair() {
  if [[ ! -s "${SSH_KEY}" ]]; then
    echo "[bootstrap] SSH private key not found → generating: ${SSH_KEY}"
    mkdir -p "$(dirname "${SSH_KEY}")"
    ssh-keygen -q -t rsa -N '' -f "${SSH_KEY}"
    chmod 600 "${SSH_KEY}"
  fi
  [[ -s "${SSH_KEY}.pub" ]] || ssh-keygen -y -f "${SSH_KEY}" > "${SSH_KEY}.pub"
}

key_ok() {
  timeout 5 ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o ConnectionAttempts=1 -i "${SSH_KEY}" "root@$1" true 2>/dev/null
}

copy_key_to() {
  local tgt="$1" pass="$2"
  ssh-keygen -q -R "${tgt}" >/dev/null 2>&1 || true
  echo "[bootstrap] ssh-copy-id → ${tgt}"
  if timeout 5 sshpass -p "$pass" ssh-copy-id \
        -i "${SSH_KEY}.pub" \
        -o StrictHostKeyChecking=no \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o ConnectTimeout=5 -o ConnectionAttempts=1 \
        "root@${tgt}" >/dev/null 2>&1; then
    return 0
  fi
  echo "[bootstrap] ssh-copy-id failed/timed out; fallback append → ${tgt}"
  timeout 5 sshpass -p "$pass" ssh \
        -o StrictHostKeyChecking=no \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o ConnectTimeout=5 -o ConnectionAttempts=1 \
        "root@${tgt}" \
        "umask 077 && mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && printf '%s\\n' '$(cat "${SSH_KEY}.pub")' >> ~/.ssh/authorized_keys"
}

# ---------- ensure sshpass on the CN itself (per your requirement) ----------
ensure_sshpass_on_cn() {
  local host="$1"
  # Try via key if available
  if key_ok "${host}"; then
    ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" bash -lc '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SVC=l UCF_FORCE_CONFFOLD=1
      if command -v sshpass >/dev/null 2>&1; then exit 0; fi
      if command -v apt-get >/dev/null 2>&1; then
        apt-get install -yq --no-install-recommends --no-upgrade sshpass
      elif command -v yum >/dev/null 2>&1; then
        yum install -y sshpass
      else
        exit 0
      fi
    ' || true
    return 0
  fi
  # Fallback via password if key not yet accepted on CN
  if command -v sshpass >/dev/null 2>&1; then
    sshpass -p "${CN_BOOTSTRAP_PASS}" ssh -o StrictHostKeyChecking=no "root@${host}" bash -lc '
      set -euo pipefail
      export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SVC=l UCF_FORCE_CONFFOLD=1
      if command -v sshpass >/dev/null 2>&1; then exit 0; fi
      if command -v apt-get >/dev/null 2>&1; then
        apt-get install -yq --no-install-recommends --no-upgrade sshpass
      elif command -v yum >/dev/null 2>&1; then
        yum install -y sshpass
      else
        exit 0
      fi
    ' || true
  fi
}

# ---------- gather hosts ----------
mapfile -t HOSTS < <(awk 'NF && $1 !~ /^#/ {
  if (index($0,":")>0) { n=split($0,a,":"); print a[2] } else { print $1 }
}' "${SERVER_FILE}")

((${#HOSTS[@]})) || { echo "[bootstrap] ❌ No hosts parsed from ${SERVER_FILE}"; exit 2; }

echo "[bootstrap] Hosts: ${HOSTS[*]}"
echo "[bootstrap] Alias IP: ${ALIAS_IP}  (from ${INSTALL_IP_ADDR})"

ensure_sshpass_runner
ensure_keypair

rc_warn=0
for host in "${HOSTS[@]}"; do
  echo; echo "─── Host ${host} ───────────────────────────────────────"

  # 1) Ensure alias IP FIRST on the CN
  if ! ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" bash -s -- "${INSTALL_IP_ADDR}" "" <<<"$ENSURE_IP_SNIPPET"; then
    echo "[bootstrap][${host}] ⚠️ Failed to ensure ${INSTALL_IP_ADDR}; continuing"
    rc_warn=1
  fi

  # 2) Ensure sshpass on the CN (requested)
  ensure_sshpass_on_cn "${host}" || true

  # 3) Fix sshd binding/auth on the CN so it listens on alias IP and allows bootstrap
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" bash -s <<<"$FIX_SSHD_SNIPPET" || {
    echo "[bootstrap][${host}] ⚠️ Could not apply sshd fixes; continuing"
    rc_warn=1
  }

  # 4) Ensure key-based SSH for host IP
  key_ok "${host}" || copy_key_to "${host}" "${CN_BOOTSTRAP_PASS}" || rc_warn=1
  key_ok "${host}" && echo "[bootstrap][${host}] ✅ key OK (host IP)" || { echo "[bootstrap][${host}] ❌ key still failing (host IP)"; rc_warn=1; }

  # 5) Ensure key-based SSH for alias IP
  if [[ -n "${ALIAS_IP}" ]]; then
    key_ok "${ALIAS_IP}" || copy_key_to "${ALIAS_IP}" "${CN_BOOTSTRAP_PASS}" || rc_warn=1
    key_ok "${ALIAS_IP}" && echo "[bootstrap][${host}] ✅ key OK (alias ${ALIAS_IP})" || { echo "[bootstrap][${host}] ⚠️ key still failing (alias ${ALIAS_IP})"; rc_warn=1; }
  fi
done

# Do not hard-fail here; install has its own robust retries.
exit 0
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

    stage('Cluster install') {
      steps {
        timeout(time: 15, unit: 'MINUTES', activity: true) {
          sh '''
            set -eu
            echo ">>> Cluster install starting (mode: ${INSTALL_MODE})"
            sed -i 's/\r$//' scripts/cluster_install.sh || true
            chmod +x scripts/cluster_install.sh
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
          '''
        }
      }
    }

    // ---------- Health check after cluster install ----------
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
    while read -r ns name ready status rest; do
      x="${ready%%/*}"; y="${ready##*/}"
      if [[ "$status" != "Running" || "$x" != "$y" ]]; then
        echo "[cluster-health] $ns/$name not healthy (READY=$ready STATUS=$status)"
        notok=1
      fi
    done < <(kubectl get pods -A --no-headers)
    return $notok
  }

  if check; then
    echo "[cluster-health] ✅ All pods Running & Ready."
    exit 0
  fi

  echo "[cluster-health] Pods not healthy, waiting 300s and retrying..."
  sleep 300

  if check; then
    echo "[cluster-health] ✅ Healthy after retry."
    exit 0
  else
    echo "[cluster-health] ❌ Pods still not healthy after 5 minutes."
    kubectl get pods -A
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

sed -i 's/\r$//' scripts/ps_config.sh || true
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
    while read -r ns name ready status rest; do
      x="${ready%%/*}"; y="${ready##*/}"
      if [[ "$status" != "Running" || "$x" != "$y" ]]; then
        echo "[ps-health] $ns/$name not healthy (READY=$ready STATUS=$status)"
        notok=1
      fi
    done < <(kubectl get pods -A --no-headers)
    return $notok
  }

  if check; then
    echo "[ps-health] ✅ All pods Running & Ready."
    exit 0
  fi

  echo "[ps-health] Pods not healthy, waiting 300s and retrying..."
  sleep 300

  if check; then
    echo "[ps-health] ✅ Healthy after retry."
    exit 0
  else
    echo "[ps-health] ❌ Pods still not healthy after 5 minutes."
    kubectl get pods -A
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
