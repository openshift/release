#!/usr/bin/env bash
# List K8s platform test entries in RHDH CI config files.
#
# Usage:
#   list-k8s-test-configs.sh --pattern <regex> [--branch <name>] [--config-dir <path>]
#
# Examples:
#   list-k8s-test-configs.sh --pattern "^e2e-aks-"
#   list-k8s-test-configs.sh --pattern "^e2e-eks-" --branch main
#   list-k8s-test-configs.sh --pattern "^e2e-gke-"
#
# Requires: yq (v4+)

set -euo pipefail

CONFIG_DIR="ci-operator/config/redhat-developer/rhdh"
PATTERN=""
FILTER_BRANCH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pattern|-p)    PATTERN="$2"; shift 2 ;;
    --branch|-b)     FILTER_BRANCH="$2"; shift 2 ;;
    --config-dir|-d) CONFIG_DIR="$2"; shift 2 ;;
    *) echo "Usage: $0 --pattern <regex> [--branch <name>] [--config-dir <path>]" >&2; exit 1 ;;
  esac
done

[[ -n "$PATTERN" ]] || { echo "ERROR: --pattern is required" >&2; exit 1; }
[[ -d "$CONFIG_DIR" ]] || { echo "ERROR: Config dir not found: ${CONFIG_DIR}" >&2; exit 1; }
command -v yq &>/dev/null || { echo "ERROR: yq (v4+) required" >&2; exit 1; }

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

  echo "$entries" | jq -r '.[] | [.as, (.steps.env.MAPT_KUBERNETES_VERSION//"N/A"), (.cron//"N/A"), (.optional//false|tostring)] | @tsv' | sort | \
    while IFS=$'\t' read -r name ver cron opt; do
      printf "  %-40s %-13s %-30s %-10s\n" "$name" "$ver" "$cron" "$opt"
    done
done

echo ""
echo "K8s version source: MAPT_KUBERNETES_VERSION in steps.env per test entry" >&2
