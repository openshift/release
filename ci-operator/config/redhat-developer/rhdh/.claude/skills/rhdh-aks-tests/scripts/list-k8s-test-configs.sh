#!/usr/bin/env bash
# List K8s platform test entries in RHDH CI config files.
#
# Usage:
#   list-k8s-test-configs.sh --pattern <regex> [--mapt-script <path>] [--branch <name>] [--config-dir <path>]
#
# Examples:
#   list-k8s-test-configs.sh --pattern "^e2e-aks-" --mapt-script .../create-commands.sh
#   list-k8s-test-configs.sh --pattern "^e2e-eks-" --branch main
#   list-k8s-test-configs.sh --pattern "^e2e-gke-"
#
# Requires: yq (v4+)

set -euo pipefail

CONFIG_DIR="ci-operator/config/redhat-developer/rhdh"
PATTERN=""
MAPT_SCRIPT=""
FILTER_BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pattern|-p)    PATTERN="$2"; shift 2 ;;
    --mapt-script)   MAPT_SCRIPT="$2"; shift 2 ;;
    --branch|-b)     FILTER_BRANCH="$2"; shift 2 ;;
    --config-dir|-d) CONFIG_DIR="$2"; shift 2 ;;
    *) echo "Usage: $0 --pattern <regex> [--mapt-script <path>] [--branch <name>] [--config-dir <path>]" >&2; exit 1 ;;
  esac
done

[[ -n "$PATTERN" ]] || { echo "ERROR: --pattern is required" >&2; exit 1; }
[[ -d "$CONFIG_DIR" ]] || { echo "ERROR: Config dir not found: ${CONFIG_DIR}" >&2; exit 1; }
command -v yq &>/dev/null || { echo "ERROR: yq (v4+) required" >&2; exit 1; }

# Extract K8s version from MAPT script if provided
K8S_VER="N/A"
if [[ -n "$MAPT_SCRIPT" && -f "$MAPT_SCRIPT" ]]; then
  K8S_VER=$(grep -oE -- '--version [0-9]+\.[0-9]+' "$MAPT_SCRIPT" | awk '{print $2}' | head -1 || echo "N/A")
fi

PREFIX="redhat-developer-rhdh-"

for f in "${CONFIG_DIR}/${PREFIX}"*.yaml; do
  [[ -f "$f" ]] || continue
  branch=$(basename "$f" | sed "s/^${PREFIX}//;s/\.yaml$//")
  [[ -n "$FILTER_BRANCH" && "$branch" != "$FILTER_BRANCH" ]] && continue

  entries=$(yq -o=json -I=0 "[.tests[] | select(.as | test(\"${PATTERN}\"))]" "$f" 2>/dev/null || true)
  [[ -z "$entries" || "$entries" == "[]" ]] && continue

  echo ""
  echo "=== Branch: ${branch} ==="
  printf "  %-40s %-13s %-30s %-10s\n" TEST_NAME K8S_VERSION CRON OPTIONAL
  printf "  %-40s %-13s %-30s %-10s\n" --------- ----------- ---- --------

  echo "$entries" | jq -r --arg v "$K8S_VER" '.[] | [.as, $v, (.cron//"N/A"), (.optional//false|tostring)] | @tsv' | sort | \
    while IFS=$'\t' read -r name ver cron opt; do
      printf "  %-40s %-13s %-30s %-10s\n" "$name" "$ver" "$cron" "$opt"
    done
done

echo ""
[[ -n "$MAPT_SCRIPT" ]] && echo "K8s version source: ${MAPT_SCRIPT}" >&2
