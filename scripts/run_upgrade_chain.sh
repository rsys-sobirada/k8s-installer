#!/bin/bash
# If CLUSTER_RESET is enabled:
#   run cluster_reset.sh; on success -> cluster_install.sh
# Else:
#   run install only (handy for re-runs)

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

CL="${CLUSTER_RESET:-No}"
shopt -s nocasematch
if [[ "$CL" =~ ^(yes|true|1)$ ]]; then
  echo "=== Phase 1: Cluster reset ==="
  bash "$DIR/cluster_reset.sh"
  echo "=== Reset succeeded ==="
  echo "=== Phase 2: Cluster install ==="
  bash "$DIR/cluster_install.sh"
else
  echo "CLUSTER_RESET disabled → running install only."
  bash "$DIR/cluster_install.sh"
fi
shopt -u nocasematch
