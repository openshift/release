#!/usr/bin/env bash
# Check OCP 4.x and RHDH lifecycle status using the Red Hat Product Life Cycles API.
#
# Usage:
#   check-ocp-lifecycle.sh                          # Show all OCP + RHDH versions
#   check-ocp-lifecycle.sh --version 4.16           # Check a specific OCP version
#   check-ocp-lifecycle.sh --rhdh-version 1.9       # Check a specific RHDH version
#   check-ocp-lifecycle.sh --rhdh-only              # Show only RHDH lifecycle + supported OCP
#
# Outputs human-readable tables to stdout and JSON summaries to stderr.
# Requires: curl, jq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIFECYCLE_API_URL="https://access.redhat.com/product-life-cycles/api/v1/products"
FILTER_OCP_VERSION=""
FILTER_RHDH_VERSION=""
RHDH_ONLY=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|-v)
      FILTER_OCP_VERSION="$2"
      shift 2
      ;;
    --rhdh-version)
      FILTER_RHDH_VERSION="$2"
      shift 2
      ;;
    --rhdh-only)
      RHDH_ONLY=true
      shift
      ;;
    *)
      echo "Usage: $0 [--version X.Y] [--rhdh-version X.Y] [--rhdh-only]" >&2
      exit 1
      ;;
  esac
done

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY="${NOW%%T*}"

# ---------------------------------------------------------------
# 1. Fetch RHDH lifecycle data
# ---------------------------------------------------------------
RHDH_RESPONSE=$(curl -s --fail \
  "${LIFECYCLE_API_URL}?name=Red+Hat+Developer+Hub" \
  -H "Accept: application/json")

if [[ -z "$RHDH_RESPONSE" ]]; then
  echo "ERROR: Failed to fetch RHDH lifecycle data from Red Hat API" >&2
  exit 1
fi

RHDH_DATA=$(echo "$RHDH_RESPONSE" | jq --arg now "$NOW" --arg filter "$FILTER_RHDH_VERSION" '
  def is_date: . and . != "N/A" and (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}") // false);

  .data[0].versions | map(
    . as $ver |
    {
      version: $ver.name,
      type: $ver.type,
      supported: ($ver.type != "End of life"),
      ga_date: ([$ver.phases[] | select(.name == "General availability") | .end_date | if is_date then split("T")[0] else "N/A" end] | first // "N/A"),
      full_support_end: ([$ver.phases[] | select(.name == "Full support") | .end_date | if is_date then split("T")[0] else . end] | first // "N/A"),
      maintenance_end: ([$ver.phases[] | select(.name == "Maintenance support") | .end_date | if is_date then split("T")[0] else . end] | first // "N/A"),
      ocp_versions: ($ver.openshift_compatibility // "" | split(", ") | map(select(. != ""))),
    }
  )
  | if $filter != "" then map(select(.version == $filter)) else . end
  | sort_by(.version | split(".") | map(tonumber))
')

if [[ -n "$FILTER_RHDH_VERSION" ]] && jq -e 'length == 0' <<<"$RHDH_DATA" >/dev/null; then
  echo "ERROR: RHDH version '${FILTER_RHDH_VERSION}' not found in lifecycle data" >&2
  exit 1
fi

# Print RHDH lifecycle table
echo "=== RHDH Lifecycle ==="
echo ""
printf "%-10s %-10s %-22s %-12s %-25s %-25s %s\n" \
  "VERSION" "SUPPORTED" "TYPE" "GA_DATE" "FULL_SUPPORT_END" "MAINTENANCE_END" "SUPPORTED_OCP_VERSIONS"
printf "%-10s %-10s %-22s %-12s %-25s %-25s %s\n" \
  "-------" "---------" "----" "-------" "----------------" "---------------" "----------------------"

echo "$RHDH_DATA" | jq -r '.[] | [
  .version,
  (if .supported then "yes" else "no" end),
  .type,
  .ga_date,
  .full_support_end,
  .maintenance_end,
  (.ocp_versions | join(", "))
] | @tsv' | \
  while IFS=$'\t' read -r ver sup type ga full maint ocp; do
    printf "%-10s %-10s %-22s %-12s %-25s %-25s %s\n" "$ver" "$sup" "$type" "$ga" "$full" "$maint" "$ocp"
  done

echo ""

# Extract the union of OCP versions supported by active RHDH releases
RHDH_SUPPORTED_OCP=$(echo "$RHDH_DATA" | jq -r '
  [.[] | select(.supported) | .ocp_versions[]] | unique
  | sort_by(split(".") | map(tonumber))
  | .[]
')

echo "OCP versions supported by active RHDH releases: $(echo "$RHDH_SUPPORTED_OCP" | tr '\n' ' ')"
echo ""

# Per active RHDH release, show which OCP versions it supports
echo "Per-release OCP support:"
echo "$RHDH_DATA" | jq -r '.[] | select(.supported) | "  RHDH \(.version): \(.ocp_versions | join(", "))"'
echo ""

# ---------------------------------------------------------------
# 2. Fetch OCP lifecycle data (unless --rhdh-only)
# ---------------------------------------------------------------
if ! $RHDH_ONLY; then
  # Query the umbrella product which contains all OCP versions (4.x and future 5.x+).
  # The jq filter in ocp-lifecycle.jq handles version filtering (>= 4.x).
  OCP_RESPONSE=$(curl -s --fail \
    "${LIFECYCLE_API_URL}?name=Red+Hat+OpenShift+Container+Platform" \
    -H "Accept: application/json")

  if [[ -z "$OCP_RESPONSE" ]]; then
    echo "ERROR: Failed to fetch OCP lifecycle data from Red Hat API" >&2
    exit 1
  fi

  # Use shared jq filter for OCP phase classification
  OCP_DATA=$(echo "$OCP_RESPONSE" | jq --arg today "$TODAY" -f "${SCRIPT_DIR}/ocp-lifecycle.jq")

  # Apply version filter if specified
  if [[ -n "$FILTER_OCP_VERSION" ]]; then
    OCP_DATA=$(echo "$OCP_DATA" | jq --arg filter "$FILTER_OCP_VERSION" 'map(select(.version == $filter))')
  fi

  if [[ -z "$OCP_DATA" ]] || [[ "$OCP_DATA" == "[]" ]]; then
    if [[ -n "$FILTER_OCP_VERSION" ]]; then
      echo "ERROR: OCP version '${FILTER_OCP_VERSION}' not found in lifecycle data" >&2
      exit 1
    fi
    echo "ERROR: No OCP version data found" >&2
    exit 1
  fi

  echo "=== OCP Lifecycle ==="
  echo ""
  printf "%-10s %-10s %-10s %-35s %-12s %-12s\n" \
    "VERSION" "OCP_SUPP" "RHDH_SUPP" "PHASE" "GA_DATE" "END_DATE"
  printf "%-10s %-10s %-10s %-35s %-12s %-12s\n" \
    "-------" "--------" "---------" "-----" "-------" "--------"

  echo "$OCP_DATA" | jq -r '.[] | [.version, (if .ocp_supported then "yes" else "no" end), .phase, .ga_date, .end_of_support_date] | @tsv' | \
    while IFS=$'\t' read -r ver sup phase ga end; do
      rhdh_sup="no"
      if echo "$RHDH_SUPPORTED_OCP" | grep -qx "$ver"; then
        rhdh_sup="yes"
      fi
      printf "%-10s %-10s %-10s %-35s %-12s %-12s\n" "$ver" "$sup" "$rhdh_sup" "$phase" "$ga" "$end"
    done
  echo ""
fi

# ---------------------------------------------------------------
# 3. JSON summary to stderr
# ---------------------------------------------------------------
RHDH_SUPPORTED_JSON=$(echo "$RHDH_DATA" | jq '[.[] | select(.supported)]')
RHDH_EOL_JSON=$(echo "$RHDH_DATA" | jq '[.[] | select(.supported | not)]')
RHDH_OCP_JSON=$(echo "$RHDH_SUPPORTED_OCP" | jq -R -s 'split("\n") | map(select(. != ""))')

SUMMARY=$(jq -n \
  --argjson rhdh_supported "$RHDH_SUPPORTED_JSON" \
  --argjson rhdh_eol "$RHDH_EOL_JSON" \
  --argjson rhdh_supported_ocp "$RHDH_OCP_JSON" \
  --arg checked_at "$NOW" \
  '{
    checked_at: $checked_at,
    rhdh_supported_count: ($rhdh_supported | length),
    rhdh_eol_count: ($rhdh_eol | length),
    rhdh_supported_versions: $rhdh_supported,
    rhdh_eol_versions: $rhdh_eol,
    ocp_versions_supported_by_rhdh: $rhdh_supported_ocp
  }')

echo "$SUMMARY" >&2
