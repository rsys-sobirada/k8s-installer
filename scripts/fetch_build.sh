withCredentials([
  usernamePassword(credentialsId: 'build-src-creds', usernameVariable: 'BUILD_SRC_USER', passwordVariable: 'BUILD_SRC_PASS'),
  sshUserPrivateKey(credentialsId: 'cn-ssh-key', keyFileVariable: 'CN_KEY', usernameVariable: 'CN_USER')
]) {
  sh '''
    set -euo pipefail
    chmod +x scripts/fetch_build_remote.sh

    echo "Targets from ${SERVER_FILE}:"
    awk 'NF && $1 !~ /^#/' "${SERVER_FILE}" || true

    NEW_VERSION="${NEW_VERSION}" \
    NEW_BUILD_PATH="${NEW_BUILD_PATH}" \
    SERVER_FILE="${SERVER_FILE}" \
    BUILD_SRC_HOST="${BUILD_SRC_HOST}" \
    BUILD_SRC_USER="${BUILD_SRC_USER}" \
    BUILD_SRC_BASE="${BUILD_SRC_BASE}" \
    BUILD_SRC_PASS="${BUILD_SRC_PASS}" \
    CN_USER="${CN_USER}" \
    CN_KEY="${CN_KEY}" \
    EXTRACT_BUILD_TARBALLS="${EXTRACT_BUILD_TARBALLS}" \
    scripts/fetch_build_remote.sh
  '''
}
