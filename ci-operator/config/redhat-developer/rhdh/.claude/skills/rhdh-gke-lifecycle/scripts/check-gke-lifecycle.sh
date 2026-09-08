#!/usr/bin/env bash
# Check GKE Kubernetes version lifecycle using endoflife.date API.
#
# Primary source: https://endoflife.date/api/google-kubernetes-engine.json
#   (auto-scraped from Google's GKE release notes)
# Cross-verify:   https://cloud.google.com/kubernetes-engine/docs/release-schedule
#
# GKE uses a pre-existing long-running cluster whose version is NOT managed
# in CI config. This script only reports available versions for reference.
#
# Usage:
#   check-gke-lifecycle.sh
#
# Requires: curl, jq

set -euo pipefail

API_URL="https://endoflife.date/api/google-kubernetes-engine.json"
TODAY=$(date -u +%Y-%m-%d)

# Fetch lifecycle data
DATA=$(curl -s --fail "$API_URL") || { echo "ERROR: Failed to fetch $API_URL" >&2; exit 1; }

echo "=== GKE Version Support (endoflife.date) ==="
echo "Supported minor versions (newest first):"
printf "  %-8s %-12s %-18s %-18s\n" VERSION STATUS "END OF SUPPORT" "RELEASE DATE"
printf "  %-8s %-12s %-18s %-18s\n" ------- ------ -------------- ------------
echo "$DATA" | jq -r --arg t "$TODAY" '
  .[] |
  (.eol // "N/A") as $eol |
  (if $eol == "N/A" then true elif ($eol | type) == "boolean" then ($eol | not) else $eol > $t end) as $supported |
  select($supported) |
  (.support // "N/A") as $support |
  (if $support == "N/A" then "Unknown"
   elif ($support | type) == "boolean" then "Unknown"
   elif $support > $t then "Standard"
   else "Maintenance" end) as $status |
  "\(.cycle)\t\($status)\t\($eol)\t\(.releaseDate // "N/A")"
' | sort -t$'\t' -k1 -rV | while IFS=$'\t' read -r ver status eol rel; do
  printf "  %-8s %-12s %-18s %-18s\n" "$ver" "$status" "$eol" "$rel"
done

echo ""
echo "NOTE: GKE uses a long-running static cluster. Version is NOT managed in CI config."
echo "      Updates require manual intervention on the cluster itself."
