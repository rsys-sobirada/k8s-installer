#!/bin/bash
# scripts/run_upgrade_chain.sh
# If CLUSTER_RESET is enabled:
#   run cluster_reset.sh; if success -> cluster_install.sh
# Else:
#   run cluster_install.sh only (handy for re-runs)

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

CL="${CLUSTER_RESET:-No}"
shopt -s nocasematch
RESET_ON="$([[ "$CL" =~ ^(yes|true|1)$ ]] && echo "1" || echo "0")"
shopt -u nocasematch

echo "CLUSTER_RESET: $CL"

if [[ "$RESET_ON" == "1" ]]; then
  echo "=== Phase 1: Cluster reset ==="
  bash "$DIR/cluster_reset.sh"
  echo "=== Reset succeeded ==="
  echo ""
  echo "=== Phase 2: Cluster install ==="
  bash "$DIR/cluster_install.sh"
else
  echo "Reset disabled — running install only."
  bash "$DIR/cluster_install.sh"
fi
