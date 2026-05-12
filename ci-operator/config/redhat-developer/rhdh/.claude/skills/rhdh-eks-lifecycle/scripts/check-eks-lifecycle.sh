#!/usr/bin/env bash
# Check EKS Kubernetes version lifecycle using the official AWS EKS docs source.
#
# Primary source: https://raw.githubusercontent.com/awsdocs/amazon-eks-user-guide (AsciiDoc)
# Cross-verify:   https://endoflife.date/api/amazon-eks.json
#
# Usage:
#   check-eks-lifecycle.sh [--mapt-ref <path>] [--test-pattern <regex>] [--config-dir <path>]
#
# Requires: curl, jq, yq (v4+), awk

set -euo pipefail

EKS_DOCS_URL="https://raw.githubusercontent.com/awsdocs/amazon-eks-user-guide/mainline/latest/ug/versioning/kubernetes-versions.adoc"
EOL_API_URL="https://endoflife.date/api/amazon-eks.json"
MAPT_REF=""
TEST_PATTERN=""
CONFIG_DIR="ci-operator/config/redhat-developer/rhdh"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mapt-ref)       MAPT_REF="$2"; shift 2 ;;
    --test-pattern)   TEST_PATTERN="$2"; shift 2 ;;
    --config-dir)     CONFIG_DIR="$2"; shift 2 ;;
    *) echo "Usage: $0 [--mapt-ref <path>] [--test-pattern <regex>] [--config-dir <path>]" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/print-configured-versions.sh"

# Fetch EKS docs source (primary)
echo "=== EKS Version Support (awsdocs/amazon-eks-user-guide) ==="
DOCS=$(curl -s --fail "$EKS_DOCS_URL") || { echo "ERROR: Failed to fetch $EKS_DOCS_URL" >&2; exit 1; }

echo "Supported minor versions:"
echo "$DOCS" | awk '
/== Available versions on standard support/{section="Standard"}
/== Available versions on extended support/{section="Extended"}
/== Amazon EKS Kubernetes release calendar/{section=""}
/^\* `[0-9]+\.[0-9]+`$/ && section != "" {
  gsub(/^\* `|`$/, ""); printf "  %-8s %s\n", $0, section
}'

echo ""
echo "Release calendar:"
printf "  %-8s %-22s %-22s %-22s %-22s\n" VERSION "UPSTREAM RELEASE" "EKS RELEASE" "END STANDARD" "END EXTENDED"
printf "  %-8s %-22s %-22s %-22s %-22s\n" ------- ---------------- ----------- ------------ ------------
echo "$DOCS" | awk '
/^\|===$/{ in_table = !in_table; next }
in_table && /^\|`[0-9]+\.[0-9]+`/ {
  version=$0; getline; upstream=$0; getline; eks_release=$0; getline; end_std=$0; getline; end_ext=$0
  gsub(/^\|/, "", version); gsub(/`/, "", version)
  gsub(/^\|/, "", upstream)
  gsub(/^\|/, "", eks_release)
  gsub(/^\|/, "", end_std)
  gsub(/^\|/, "", end_ext)
  printf "  %-8s %-22s %-22s %-22s %-22s\n", version, upstream, eks_release, end_std, end_ext
}'

# Cross-verify with endoflife.date
echo ""
echo "=== Cross-verify (endoflife.date) ==="
TODAY=$(date -u +%Y-%m-%d)
EOL_DATA=$(curl -s --fail "$EOL_API_URL" 2>/dev/null) || { echo "WARNING: Failed to fetch endoflife.date" >&2; exit 0; }
echo "$EOL_DATA" | jq -r --arg t "$TODAY" '
  def any_support($t):
    ((.eol // "N/A") as $e | (.extendedSupport // "N/A") as $x |
      (if $e == "N/A" then true elif ($e | type) == "boolean" then ($e | not) else $e > $t end) or
      (if $x == "N/A" then false elif ($x | type) == "boolean" then ($x | not) else $x > $t end));
  map(select(any_support($t)))
  | sort_by(.cycle | split(".") | map(tonumber))
  | reverse
  | .[] | "  \(.cycle)\tEOL: \(.eol // "N/A")\tExtended: \(.extendedSupport // "N/A")"
'
