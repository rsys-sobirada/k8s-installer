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

    // -------- OPTIONAL bootstrap controls --------
    password(
      name: 'CN_BOOTSTRAP_PASS',
      defaultValue: '',
      description: 'One-time CN root password used by bootstrap_keys.sh'
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
    INSTALL_IP_ADDR  = "${params.INSTALL_IP_ADDR}"      // ensure env matches param
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
          if (!params.CN_BOOTSTRAP_PASS?.trim()) {
            echo "[warn] CN_BOOTSTRAP_PASS is empty; bootstrap_keys.sh will prompt if ssh-copy-id needs a password."
          }
        }
      }
    }

    // ---------------- Pre-bootstrap (Fresh only) ----------------
stage('Pre-bootstrap keys (Fresh only)') {
  when { expression { return params.INSTALL_MODE == 'Fresh_installation' } }
  steps {
    timeout(time: 10, unit: 'MINUTES', activity: true) {
      sh '''#!/usr/bin/env bash
set -euo pipefail

alias_ip_cidr="${INSTALL_IP_ADDR}"
alias_ip="${alias_ip_cidr%%/*}"
echo "[bootstrap][runner] Hosts: $(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){ split($0,a,":"); print a[2] } else { print $1 } }' "${SERVER_FILE}" | paste -sd, -)"
echo "[bootstrap][runner] Alias IP: ${alias_ip}  (from ${alias_ip_cidr})"
echo

# Parse hosts
mapfile -t HOSTS < <(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){split($0,a,":"); print a[2]} else {print $1} }' "${SERVER_FILE}")
[[ ${#HOSTS[@]} -gt 0 ]] || { echo "no hosts in ${SERVER_FILE}"; exit 2; }

ENSURE_IP_SNIPPET='set -euo pipefail
CIDR="$1"
present(){ ip -4 addr show | awk "/inet /{print \\$2}" | grep -qx "$CIDR"; }
if present; then echo "[IP] Present: $CIDR"; exit 0; fi
IF=$(ip route 2>/dev/null | awk "/^default/{print \\$5; exit}" || true)
if [[ -z "$IF" ]]; then IF=$(ip -o link | awk -F": " "{print \\$2}" | grep -E "^(en|eth|ens|eno|em)[0-9A-Za-z._-]+" | head -n1 || true); fi
[[ -z "$IF" ]] && { echo "[IP] no iface"; exit 1; }
echo "[IP] Trying $CIDR on iface $IF..."; ip link set dev "$IF" up || true
ip addr replace "$CIDR" dev "$IF" && echo "[IP] OK on $IF" || { echo "[IP] failed"; exit 2; }'

for host in "${HOSTS[@]}"; do
  echo "─── Host ${host} ───────────────────────────────────────"
  # 1) ensure alias IP on CN
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" bash -s -- "${INSTALL_IP_ADDR}" <<<"$ENSURE_IP_SNIPPET"

  # 2) push script and chmod
  scp -o StrictHostKeyChecking=no -i "${SSH_KEY}" scripts/bootstrap_keys.sh "root@${host}:/root/bootstrap_keys.sh"
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" chmod +x /root/bootstrap_keys.sh
  echo "✅ Script integrity OK on ${host}"

  # 3) ensure sshpass on CN
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" bash -lc '
    set -euo pipefail
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export NEEDRESTART_SVC=l
    if ! command -v sshpass >/dev/null 2>&1; then
      apt-get install -yq --no-install-recommends --no-upgrade sshpass
      echo "[CN] sshpass INSTALLED"
    else
      echo "[CN] sshpass present"
    fi
  '

  # 4) RUN bootstrap_keys.sh — NO FLAGS, PASS ENVS
  echo "[run] /root/bootstrap_keys.sh (env INSTALL_IP_ADDR + CN_BOOTSTRAP_PASS)"
  ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" bash -lc "INSTALL_IP_ADDR='${INSTALL_IP_ADDR}' CN_BOOTSTRAP_PASS='${CN_BOOTSTRAP_PASS}' /root/bootstrap_keys.sh"
done
'''
    }
  }
}


    // ---------------- Reset &/or Fetch (parallel) ----------------
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

    // ---------------- Cluster install (with auto re-bootstrap on Permission denied) ----------------
    stage('Cluster install') {
      steps {
        timeout(time: 20, unit: 'MINUTES', activity: true) {
          script {
            def rc = sh(returnStatus: true, script: '''
              set -eu
              echo ">>> Cluster install starting (mode: ${INSTALL_MODE})"
              sed -i 's/\\r$//' scripts/cluster_install.sh || true
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
              bash -euo pipefail scripts/cluster_install.sh | tee install_stage.log
            ''')

// If failed due to SSH permission, run bootstrap on CN(s) and retry once
if (rc != 0) {
  def denied = sh(returnStatus: true, script: "grep -E 'Permission denied \\(publickey,password\\)|ANSIBLE_SSH_DENIED' install_stage.log >/dev/null 2>&1")
  if (denied == 0) {
    echo "[Cluster install] Detected SSH permission error → running bootstrap_keys.sh on CN(s) then retrying once..."
    sh '''
      set -euo pipefail
      mapfile -t HOSTS < <(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0){split($0,a,":"); print a[2]} else {print $1} }' "${SERVER_FILE}")
      for host in "${HOSTS[@]}"; do
        scp -o StrictHostKeyChecking=no -i "${SSH_KEY}" scripts/bootstrap_keys.sh "root@${host}:/root/bootstrap_keys.sh"
        ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" chmod +x /root/bootstrap_keys.sh
        # ensure sshpass
        ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" bash -lc '
          set -euo pipefail
          export DEBIAN_FRONTEND=noninteractive
          export NEEDRESTART_MODE=a
          export NEEDRESTART_SVC=l
          if ! command -v sshpass >/dev/null 2>&1; then
            apt-get install -yq --no-install-recommends --no-upgrade sshpass
          fi
        '
        # RUN bootstrap_keys.sh — NO FLAGS, PASS ENVS
        ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${host}" bash -lc "INSTALL_IP_ADDR='${INSTALL_IP_ADDR}' CN_BOOTSTRAP_PASS='${CN_BOOTSTRAP_PASS}' /root/bootstrap_keys.sh"
      done
    '''
    // retry once
    sh '''
      set -eu
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
  } else {
    error("Cluster install failed; see console or install_stage.log")
  }
}


    // ---------- Health check after cluster install ----------
    stage('Cluster health check') {
      steps {
        timeout(time: 10, unit: 'MINUTES', activity: true) {
          sh '''#!/usr/bin/env bash
set -euo pipefail
HOST="$(awk 'NF && $1 !~ /^#/ { if (index($0,":")>0) { n=split($0,a,":"); print a[2]; exit } else { print $1; exit } }' "${SERVER_FILE}")"
[[ -n "${HOST}" ]] || { echo "[cluster-health] ERROR: could not parse host from ${SERVER_FILE}" >&2; exit 2; }
echo "[cluster-health] Using host ${HOST} for kubectl checks"

ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail
  export KUBECONFIG=/etc/kubernetes/admin.conf
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "[cluster-health] kubectl not found; cluster likely not installed."
    exit 0
  fi
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
  else
    echo "[cluster-health] Pods not healthy, waiting 300s and retrying..."
    sleep 300
    if check; then
      echo "[cluster-health] ✅ Healthy after retry."
    else
      echo "[cluster-health] ❌ Pods still not healthy after 5 minutes."
      kubectl get pods -A || true
      exit 1
    fi
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
[[ -n "${HOST}" ]] || { echo "[ps-health] ERROR: could not parse host from ${SERVER_FILE}" >&2; exit 2; }
echo "[ps-health] Using host ${HOST} for kubectl checks"
ssh -o StrictHostKeyChecking=no -i "${SSH_KEY}" "root@${HOST}" bash -lc '
  set -euo pipefail
  export KUBECONFIG=/etc/kubernetes/admin.conf
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "[ps-health] kubectl not found; cluster likely not installed."
    exit 0
  fi
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
  else
    echo "[ps-health] Pods not healthy, waiting 300s and retrying..."
    sleep 300
    if check; then
      echo "[ps-health] ✅ Healthy after retry."
    else
      echo "[ps-health] ❌ Pods still not healthy after 5 minutes."
      kubectl get pods -A || true
      exit 1
    fi
  fi
'
'''
        }
      }
    }
  }

  post {
    always {
      archiveArtifacts artifacts: '**/*.log', allowEmptyArchive: true
    }
  }
}
