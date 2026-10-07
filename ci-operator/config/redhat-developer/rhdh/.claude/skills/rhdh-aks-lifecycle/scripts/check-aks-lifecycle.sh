#!/usr/bin/env bash
# Check AKS Kubernetes version lifecycle using the official AKS release status API.
#
# Primary source: https://releases.aks.azure.com/parsed_data.json
# Cross-verify:   https://endoflife.date/api/azure-kubernetes-service.json
#
# Usage:
#   check-k8s-lifecycle.sh [--mapt-ref <path>] [--test-pattern <regex>] [--config-dir <path>]
#
# Requires: curl, jq, yq (v4+)

set -euo pipefail

AKS_API_URL="https://releases.aks.azure.com/parsed_data.json"
EOL_API_URL="https://endoflife.date/api/azure-kubernetes-service.json"
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

# Fetch AKS release data (primary source)
echo "=== AKS Release Status (releases.aks.azure.com) ==="
DATA=$(curl -s --fail "$AKS_API_URL") || { echo "ERROR: Failed to fetch $AKS_API_URL" >&2; exit 1; }

# Extract unique major.minor versions from the first region's KubernetesVersionList
VERSIONS=$(echo "$DATA" | jq -r '
  .Sections.KubernetesSupportedVersions.Components.KubernetesVersions.RegionalStatuses
  | to_entries[0].value[0].Current.KubernetesVersionList
  | [.[] | {minor: (.VersionName | split(".")[0:2] | join(".")), isLTS: .IsLTS, isPreview: .IsPreview}]
  | group_by(.minor)
  | map({minor: .[0].minor, isLTS: (map(.isLTS) | any), isPreview: (map(.isPreview) | any)})
  | sort_by(.minor | split(".") | map(tonumber))
  | reverse
  | .[] | "\(.minor)\t\(if .isLTS then "LTS" elif .isPreview then "Preview" else "GA" end)"
')

DEPRECATED=$(echo "$DATA" | jq -r '
  .Sections.KubernetesSupportedVersions.Components.KubernetesVersions.RegionalStatuses
  | to_entries[0].value[0].Current.DeprecatedVersion // "N/A"
')

echo "Supported minor versions (newest first):"
echo "$VERSIONS" | while IFS=$'\t' read -r ver status; do
  printf "  %-8s %s\n" "$ver" "$status"
done
echo "Recently deprecated: ${DEPRECATED}"

# Cross-verify with endoflife.date
echo ""
echo "=== Cross-verify (endoflife.date) ==="
EOL_DATA=$(curl -s --fail "$EOL_API_URL" 2>/dev/null) || { echo "WARNING: Failed to fetch endoflife.date" >&2; exit 0; }
TODAY=$(date -u +%Y-%m-%d)
echo "$EOL_DATA" | jq -r --arg t "$TODAY" '
  def any_support($t):
    ((.eol // "N/A") as $e | (.extendedSupport // "N/A") as $x |
      (if $e == "N/A" then true elif ($e | type) == "boolean" then ($e | not) else $e > $t end) or
      (if $x == "N/A" then false elif ($x | type) == "boolean" then ($x | not) else $x > $t end));
  map(select(any_support($t)))
  | sort_by(.cycle | split(".") | map(tonumber))
  | reverse
  | .[] | "  \(.cycle)\tEOL: \(.eol // "N/A")"
'
