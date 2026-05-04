#!/usr/bin/env bash
# Check Kubernetes version lifecycle for a managed K8s platform using endoflife.date.
#
# Usage:
#   check-k8s-lifecycle.sh --api-url <url> [--mapt-script <path>] [--mapt-ref <path>]
#
# Requires: curl, jq

set -euo pipefail

API_URL=""
MAPT_SCRIPT=""
MAPT_REF=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --api-url)       API_URL="$2"; shift 2 ;;
    --mapt-script)   MAPT_SCRIPT="$2"; shift 2 ;;
    --mapt-ref)      MAPT_REF="$2"; shift 2 ;;
    *) echo "Usage: $0 --api-url <url> [--mapt-script <path>] [--mapt-ref <path>]" >&2; exit 1 ;;
  esac
done

[[ -n "$API_URL" ]] || { echo "ERROR: --api-url is required" >&2; exit 1; }

TODAY=$(date -u +%Y-%m-%d)

# Extract configured version from MAPT script (if provided)
CONFIGURED=""
if [[ -n "$MAPT_SCRIPT" && -f "$MAPT_SCRIPT" ]]; then
  CONFIGURED=$(grep -oE -- '--version [0-9]+\.[0-9]+' "$MAPT_SCRIPT" | awk '{print $2}' | head -1 || true)
fi

# Extract MAPT image tag (if provided)
MAPT_TAG=""
if [[ -n "$MAPT_REF" && -f "$MAPT_REF" ]]; then
  MAPT_TAG=$(grep 'tag:' "$MAPT_REF" | awk '{print $2}' | head -1 || true)
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
if [[ -n "$CONFIGURED" ]]; then
  echo "Configured: ${CONFIGURED}"
  [[ -n "$MAPT_TAG" ]] && echo "MAPT image: mapt:${MAPT_TAG}"
  echo "Source:     ${MAPT_SCRIPT}"
fi
echo "Newest:  ${NEWEST} (GA: ${NEWEST_GA}, EOL: ${NEWEST_EOL})"
echo "Oldest:  ${OLDEST} (GA: ${OLDEST_GA}, EOL: ${OLDEST_END})"
