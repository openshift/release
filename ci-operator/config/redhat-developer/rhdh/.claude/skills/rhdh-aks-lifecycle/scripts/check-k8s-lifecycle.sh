#!/usr/bin/env bash
# Check Kubernetes version lifecycle for a managed K8s platform using endoflife.date.
#
# Usage:
#   check-k8s-lifecycle.sh --api-url <url> [--mapt-ref <path>] [--test-pattern <regex>] [--config-dir <path>]
#
# Requires: curl, jq, yq (v4+)

set -euo pipefail

API_URL=""
MAPT_REF=""
TEST_PATTERN=""
CONFIG_DIR="ci-operator/config/redhat-developer/rhdh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-url)        API_URL="$2"; shift 2 ;;
    --mapt-ref)       MAPT_REF="$2"; shift 2 ;;
    --test-pattern)   TEST_PATTERN="$2"; shift 2 ;;
    --config-dir)     CONFIG_DIR="$2"; shift 2 ;;
    *) echo "Usage: $0 --api-url <url> [--mapt-ref <path>] [--test-pattern <regex>] [--config-dir <path>]" >&2; exit 1 ;;
  esac
done

[[ -n "$API_URL" ]] || { echo "ERROR: --api-url is required" >&2; exit 1; }

TODAY=$(date -u +%Y-%m-%d)

# Extract MAPT image tag (if provided)
MAPT_TAG=""
if [[ -n "$MAPT_REF" && -f "$MAPT_REF" ]]; then
  MAPT_TAG=$(grep 'tag:' "$MAPT_REF" | awk '{print $2}' | head -1 || true)
fi

# Extract configured versions from CI config files (per branch)
if [[ -n "$TEST_PATTERN" && -d "$CONFIG_DIR" ]] && command -v yq &>/dev/null; then
  PREFIX="redhat-developer-rhdh-"
  echo "Configured MAPT_KUBERNETES_VERSION per branch:"
  for f in "${CONFIG_DIR}/${PREFIX}"*.yaml; do
    [[ -f "$f" ]] || continue
    branch=$(basename "$f" | sed "s/^${PREFIX}//;s/\.yaml$//")
    ver=$(yq -o=json "[.tests[] | select(.as | test(\"${TEST_PATTERN}\")) | .steps.env.MAPT_KUBERNETES_VERSION // \"N/A\"] | unique | .[]" "$f" 2>/dev/null | sort -u | paste -sd',' - || echo "N/A")
    [[ -z "$ver" ]] && ver="N/A"
    echo "  ${branch}: ${ver}"
  done
  [[ -n "$MAPT_TAG" ]] && echo "MAPT image: mapt:${MAPT_TAG}"
  echo ""
fi

# Fetch lifecycle data
DATA=$(curl -s --fail "$API_URL") || { echo "ERROR: Failed to fetch $API_URL" >&2; exit 1; }

# jq: extract newest and oldest supported (including extended support), with dates
RESULT=$(echo "$DATA" | jq -r --arg t "$TODAY" '
  def date_str: if . == "N/A" or (type == "boolean") then "N/A" else . end;
  def any_support($t):
    ((.eol // "N/A") as $e | (.extendedSupport // "N/A") as $x |
      (if $e == "N/A" then true elif ($e | type) == "boolean" then ($e | not) else $e > $t end) or
      (if $x == "N/A" then false elif ($x | type) == "boolean" then ($x | not) else $x > $t end));
  def latest_date: [(.eol // "N/A"), (.extendedSupport // "N/A")] | map(select(. != "N/A" and (type != "boolean"))) | sort | last // "N/A";
  map(select(any_support($t)))
  | sort_by(.cycle | split(".") | map(tonumber))
  | if length == 0 then "none|N/A|N/A|none|N/A|N/A"
    else "\(last.cycle)|\(last.releaseDate // "N/A")|\(last.eol | date_str)|\(first.cycle)|\(first.releaseDate // "N/A")|\(first | latest_date)" end
')

IFS='|' read -r NEWEST NEWEST_GA NEWEST_EOL OLDEST OLDEST_GA OLDEST_END <<< "$RESULT"

# Print summary
echo "Newest:  ${NEWEST} (GA: ${NEWEST_GA}, EOL: ${NEWEST_EOL})"
echo "Oldest:  ${OLDEST} (GA: ${OLDEST_GA}, EOL: ${OLDEST_END})"
