#!/usr/bin/env bash
# Analyze RHDH OCP version coverage: cross-reference cluster pools, CI test
# configs, RHDH lifecycle, and OCP lifecycle data.
#
# Two dimensions are checked:
#   1. OCP lifecycle — is the OCP version itself still supported? (Full, Maintenance, EUS)
#   2. RHDH compatibility — does RHDH officially list this OCP version in its
#      openshift_compatibility field?
#
# The RHDH lifecycle API is the source of truth for which OCP versions each
# RHDH release supports. The "main" branch targets the next unreleased RHDH
# release which typically supports the latest OCP versions that just went GA,
# so main is mapped to a superset: the latest RHDH release's OCP list plus
# any newer OCP versions that are supported (GA'd).
#
# Usage:
#   analyze-coverage.sh
#   analyze-coverage.sh --pool-dir <path> --config-dir <path>
#
# Must be run from the root of the openshift/release repository.
# Requires: curl, jq, yq (v4+)

set -euo pipefail

# Resolve path to the shared jq filter for OCP lifecycle classification.
# This filter lives in the rhdh-ocp-lifecycle skill and is the single source
# of truth for OCP phase classification. If that skill is moved or renamed,
# this path must be updated.
# See: rhdh-ocp-lifecycle/scripts/ocp-lifecycle.jq
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OCP_LIFECYCLE_JQ="${SCRIPT_DIR}/../../rhdh-ocp-lifecycle/scripts/ocp-lifecycle.jq"

POOL_DIR="clusters/hosted-mgmt/hive/pools/rhdh"
CI_CONFIG_DIR="ci-operator/config/redhat-developer/rhdh"
LIFECYCLE_API_URL="https://access.redhat.com/product-life-cycles/api/v1/products"

usage() { echo "Usage: $0 [--pool-dir <path>] [--config-dir <path>]" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool-dir)
      [[ $# -ge 2 && "${2:0:2}" != "--" ]] || usage
      POOL_DIR="$2"
      shift 2
      ;;
    --config-dir)
      [[ $# -ge 2 && "${2:0:2}" != "--" ]] || usage
      CI_CONFIG_DIR="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

# Validate prerequisites
for cmd in curl jq yq; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: ${cmd} is required but not found" >&2
    exit 1
  fi
done

# Associative arrays require bash 4+; macOS ships bash 3.2 by default.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
  echo "ERROR: bash 4+ is required (associative arrays). Found: ${BASH_VERSION}" >&2
  echo "On macOS, install a newer bash: brew install bash" >&2
  exit 1
fi

if [[ ! -d "$POOL_DIR" ]]; then
  echo "ERROR: Pool directory not found: ${POOL_DIR}" >&2
  exit 1
fi

if [[ ! -d "$CI_CONFIG_DIR" ]]; then
  echo "ERROR: Config directory not found: ${CI_CONFIG_DIR}" >&2
  exit 1
fi

echo "========================================================"
echo "  RHDH OCP Coverage Analysis"
echo "========================================================"
echo ""
echo "Pool directory:   ${POOL_DIR}"
echo "Config directory: ${CI_CONFIG_DIR}"
echo "Analysis time:    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# ---------------------------------------------------------------
# 1. Gather cluster pool versions
# ---------------------------------------------------------------
echo "--- Cluster Pools ---"
POOL_VERSIONS=()
for pool_file in "${POOL_DIR}"/*_clusterpool.yaml; do
  [[ -f "$pool_file" ]] || continue
  ver=$(yq '.metadata.labels.version' "$pool_file" 2>/dev/null) || true
  [[ -z "$ver" || "$ver" == "null" ]] && continue
  pool_name=$(yq '.metadata.name // "unknown"' "$pool_file" 2>/dev/null) || true
  size=$(yq '.spec.size // 0' "$pool_file" 2>/dev/null) || true
  max=$(yq '.spec.maxSize // 0' "$pool_file" 2>/dev/null) || true
  POOL_VERSIONS+=("$ver")
  printf "  %-8s  %-25s  size=%s max=%s\n" "$ver" "$pool_name" "$size" "$max"
done
echo ""

# ---------------------------------------------------------------
# 2. Gather test config versions per branch
# ---------------------------------------------------------------
echo "--- Test Configs ---"
# shellcheck disable=SC2206  # Intentional word-splitting on path separators (no spaces in paths)
dir_parts=(${CI_CONFIG_DIR//\// })
if [[ ${#dir_parts[@]} -lt 2 ]]; then
  echo "ERROR: --config-dir must contain at least two path components (got: ${CI_CONFIG_DIR})" >&2
  exit 1
fi
CONFIG_PREFIX="${dir_parts[-2]}-${dir_parts[-1]}-"

declare -A BRANCH_VERSIONS  # branch -> space-separated versions
ALL_TEST_VERSIONS=()

for config_file in "${CI_CONFIG_DIR}/${CONFIG_PREFIX}"*.yaml; do
  [[ -f "$config_file" ]] || continue
  filename=$(basename "$config_file")
  branch="${filename#"${CONFIG_PREFIX}"}"
  branch="${branch%.yaml}"

  # Extract OCP versions from cluster_claim.version (the source of truth),
  # not from test names. Tests like e2e-ocp-helm-nightly don't encode the
  # version in the name but use OCP 4.18 via cluster_claim.version.
  versions=$(yq -o=json -I=0 \
    '[.tests[] | select(.cluster_claim.version != null) | .cluster_claim.version] | unique | .[]' \
    "$config_file" 2>/dev/null | tr -d '"' | sort -V || true)

  if [[ -n "$versions" ]]; then
    BRANCH_VERSIONS["$branch"]="$versions"
    while IFS= read -r v; do
      ALL_TEST_VERSIONS+=("$v")
    done <<< "$versions"
    echo "  ${branch}: $(echo "$versions" | tr '\n' ' ')"
  fi
done
echo ""

# shellcheck disable=SC2207  # Intentional word-splitting; version strings contain no spaces
UNIQUE_TEST_VERSIONS=($(printf '%s\n' "${ALL_TEST_VERSIONS[@]}" | sort -uV))

# ---------------------------------------------------------------
# 3. Fetch RHDH lifecycle data
# ---------------------------------------------------------------
echo "--- RHDH Lifecycle ---"
echo "  Fetching from Red Hat Product Life Cycles API..."

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TODAY="${NOW%%T*}"

RHDH_RESPONSE=$(curl -s --fail \
  "${LIFECYCLE_API_URL}?name=Red+Hat+Developer+Hub" \
  -H "Accept: application/json")

if [[ -z "$RHDH_RESPONSE" ]]; then
  echo "ERROR: Failed to fetch RHDH lifecycle data" >&2
  exit 1
fi

RHDH_DATA=$(echo "$RHDH_RESPONSE" | jq '
  .data[0].versions | map({
    version: .name,
    type: .type,
    supported: (.type != "End of life"),
    ocp_versions: (.openshift_compatibility // "" | split(", ") | map(select(. != "")))
  })
  | sort_by(.version | split(".") | map(tonumber))
')

echo "$RHDH_DATA" | jq -r '.[] | select(.supported) | "  RHDH \(.version) (\(.type)): OCP \(.ocp_versions | join(", "))"'

# Union of OCP versions supported by any active RHDH release
RHDH_SUPPORTED_OCP=$(echo "$RHDH_DATA" | jq -r '
  [.[] | select(.supported) | .ocp_versions[]] | unique
  | sort_by(split(".") | map(tonumber))
  | .[]
')
echo ""
echo "  OCP versions supported by active RHDH releases: $(echo "$RHDH_SUPPORTED_OCP" | tr '\n' ' ')"
echo ""

# Build per-RHDH-release -> OCP version mapping
# Maps RHDH version to product branch: 1.9 -> release-1.9, 1.8 -> release-1.8
declare -A RHDH_BRANCH_OCP  # product_branch -> space-separated OCP versions
LATEST_RHDH_OCP=""

while IFS=$'\t' read -r rhdh_ver ocp_list; do
  branch="release-${rhdh_ver}"
  RHDH_BRANCH_OCP["$branch"]="$ocp_list"
  LATEST_RHDH_OCP="$ocp_list"
done < <(echo "$RHDH_DATA" | jq -r '.[] | select(.supported) | [.version, (.ocp_versions | join(" "))] | @tsv')

# ---------------------------------------------------------------
# 4. Fetch OCP lifecycle data
# ---------------------------------------------------------------
echo "--- OCP Lifecycle ---"
echo "  Fetching from Red Hat Product Life Cycles API..."

# Query the umbrella product which contains all OCP versions (4.x and future 5.x+).
# The jq filter in ocp-lifecycle.jq handles version filtering (>= 4.x).
OCP_RESPONSE=$(curl -s --fail \
  "${LIFECYCLE_API_URL}?name=Red+Hat+OpenShift+Container+Platform" \
  -H "Accept: application/json")

if [[ -z "$OCP_RESPONSE" ]]; then
  echo "ERROR: Failed to fetch OCP lifecycle data" >&2
  exit 1
fi

# Use shared jq filter for OCP phase classification
OCP_LIFECYCLE=$(echo "$OCP_RESPONSE" | jq --arg today "$TODAY" -f "${OCP_LIFECYCLE_JQ}")

OCP_SUPPORTED=$(echo "$OCP_LIFECYCLE" | jq -r '[.[] | select(.ocp_supported) | .version] | .[]')
OCP_EOL=$(echo "$OCP_LIFECYCLE" | jq -r '[.[] | select(.ocp_supported | not) | .version] | .[]')

echo "  OCP supported:     $(echo "$OCP_SUPPORTED" | tr '\n' ' ')"
echo "  OCP end-of-life:   $(echo "$OCP_EOL" | tr '\n' ' ')"
echo ""

# Compute "main" branch OCP support:
# main targets the next unreleased RHDH, which supports the latest RHDH release's
# OCP versions PLUS any newer OCP versions that have reached GA (are supported).
# This means: latest RHDH OCP list ∪ any OCP versions newer than the max in that list.
if [[ -n "$LATEST_RHDH_OCP" ]]; then
  # Find the highest OCP version in the latest RHDH release
  MAX_RHDH_OCP=$(echo "$LATEST_RHDH_OCP" | tr ' ' '\n' | sort -V | tail -1)
  MAX_MAJOR="${MAX_RHDH_OCP%%.*}"
  MAX_MINOR="${MAX_RHDH_OCP#*.}"

  # Start with the latest RHDH release's OCP versions
  MAIN_OCP="$LATEST_RHDH_OCP"

  # Add any supported OCP versions newer than the max
  while IFS= read -r ocp_ver; do
    [[ -z "$ocp_ver" ]] && continue
    ver_major="${ocp_ver%%.*}"
    ver_minor="${ocp_ver#*.}"
    if [[ "$ver_major" -gt "$MAX_MAJOR" ]] || \
       { [[ "$ver_major" -eq "$MAX_MAJOR" ]] && [[ "$ver_minor" -gt "$MAX_MINOR" ]]; }; then
      MAIN_OCP="$MAIN_OCP $ocp_ver"
    fi
  done <<< "$OCP_SUPPORTED"

  RHDH_BRANCH_OCP["main"]="$MAIN_OCP"
fi

# ---------------------------------------------------------------
# 5. Combined OCP version matrix
# ---------------------------------------------------------------
echo "--- OCP Version Matrix ---"
echo ""
printf "  %-8s  %-10s  %-10s  %-30s  %s\n" \
  "OCP" "OCP_SUPP" "RHDH_SUPP" "OCP_PHASE" "RHDH_RELEASES"
printf "  %-8s  %-10s  %-10s  %-30s  %s\n" \
  "---" "--------" "---------" "---------" "-------------"

# Show all OCP versions that appear in pools, tests, or either lifecycle
ALL_RELEVANT_OCP=$( {
  printf '%s\n' "${POOL_VERSIONS[@]}" "${UNIQUE_TEST_VERSIONS[@]}"
  printf '%s\n' "$RHDH_SUPPORTED_OCP"
  printf '%s\n' "$OCP_SUPPORTED"
} | sort -uV)

while IFS= read -r ver; do
  [[ -z "$ver" ]] && continue

  # OCP supported?
  ocp_sup="no"
  ocp_phase="N/A"
  phase_data=$(echo "$OCP_LIFECYCLE" | jq -r --arg v "$ver" '.[] | select(.version == $v) | "\(.ocp_supported)\t\(.phase)"' 2>/dev/null || true)
  if [[ -n "$phase_data" ]]; then
    ocp_sup_raw=$(echo "$phase_data" | cut -f1)
    ocp_phase=$(echo "$phase_data" | cut -f2)
    [[ "$ocp_sup_raw" == "true" ]] && ocp_sup="yes"
  fi

  # RHDH supported?
  rhdh_sup="no"
  rhdh_releases=""
  if echo "$RHDH_SUPPORTED_OCP" | grep -Fxq "$ver"; then
    rhdh_sup="yes"
    rhdh_releases=$(echo "$RHDH_DATA" | jq -r --arg v "$ver" '[.[] | select(.supported) | select(.ocp_versions[] == $v) | .version] | join(", ")' 2>/dev/null || true)
  fi

  printf "  %-8s  %-10s  %-10s  %-30s  %s\n" "$ver" "$ocp_sup" "$rhdh_sup" "$ocp_phase" "$rhdh_releases"
done <<< "$ALL_RELEVANT_OCP"
echo ""

# ---------------------------------------------------------------
# 6. Cross-reference analysis
# ---------------------------------------------------------------
echo "========================================================"
echo "  Analysis Results"
echo "========================================================"
echo ""

HAS_ACTIONS=false

# 6a. Pools for OCP versions that are OCP-EOL
echo "--- Pools for OCP-EOL Versions (REMOVE) ---"
EOL_POOL_COUNT=0
for ver in "${POOL_VERSIONS[@]}"; do
  if echo "$OCP_EOL" | grep -Fxq "$ver"; then
    echo "  REMOVE pool: ${ver} (OCP end-of-life)"
    EOL_POOL_COUNT=$((EOL_POOL_COUNT + 1))
    HAS_ACTIONS=true
  fi
done
if [[ $EOL_POOL_COUNT -eq 0 ]]; then
  echo "  (none)"
fi
echo ""

# 6b. Pools for OCP versions not supported by any active RHDH release
echo "--- Pools for Non-RHDH-Supported OCP Versions (REVIEW) ---"
NOTRHDH_POOL_COUNT=0
for ver in "${POOL_VERSIONS[@]}"; do
  # Skip if already flagged as OCP-EOL above
  if echo "$OCP_EOL" | grep -Fxq "$ver"; then
    continue
  fi
  if ! echo "$RHDH_SUPPORTED_OCP" | grep -Fxq "$ver"; then
    echo "  REVIEW pool: ${ver} (OCP still supported, but not listed in any active RHDH release)"
    NOTRHDH_POOL_COUNT=$((NOTRHDH_POOL_COUNT + 1))
    HAS_ACTIONS=true
  fi
done
if [[ $NOTRHDH_POOL_COUNT -eq 0 ]]; then
  echo "  (none)"
fi
echo ""

# 6c. Test entries for OCP versions not matching the branch's RHDH compatibility
echo "--- Test Entries Mismatched With RHDH Compatibility (REVIEW) ---"
MISMATCH_TEST_COUNT=0
for branch in "${!BRANCH_VERSIONS[@]}"; do
  branch_rhdh_ocp="${RHDH_BRANCH_OCP[$branch]:-}"
  for ver in ${BRANCH_VERSIONS[$branch]}; do
    # Flag if OCP-EOL
    if echo "$OCP_EOL" | grep -Fxq "$ver"; then
      echo "  REMOVE test: ${ver} from ${branch} (OCP end-of-life)"
      MISMATCH_TEST_COUNT=$((MISMATCH_TEST_COUNT + 1))
      HAS_ACTIONS=true
      continue
    fi
    # Flag if not in RHDH compatibility for this branch
    if [[ -n "$branch_rhdh_ocp" ]]; then
      if ! echo "$branch_rhdh_ocp" | tr ' ' '\n' | grep -Fxq "$ver"; then
        echo "  REVIEW test: ${ver} in ${branch} (not in RHDH openshift_compatibility for this release)"
        MISMATCH_TEST_COUNT=$((MISMATCH_TEST_COUNT + 1))
        HAS_ACTIONS=true
      fi
    fi
  done
done
if [[ $MISMATCH_TEST_COUNT -eq 0 ]]; then
  echo "  (none)"
fi
echo ""

# 6d. RHDH-supported OCP versions missing cluster pools
# Only recommend adding pools for versions that are BOTH RHDH-supported AND OCP-supported.
# If OCP is EOL, there's no point adding a pool even if RHDH still lists it.
# Iterate the union of RHDH_BRANCH_OCP values (includes main's computed extras).
echo "--- RHDH-Supported OCP Versions Missing Pools (ADD) ---"
MISSING_POOL_COUNT=0
RHDH_ALL_OCP=$( {
  for _b in "${!RHDH_BRANCH_OCP[@]}"; do printf '%s\n' ${RHDH_BRANCH_OCP[$_b]}; done
} | sort -uV)
while IFS= read -r ver; do
  [[ -z "$ver" ]] && continue
  # Skip OCP-EOL versions — no pool should be created for an EOL OCP
  if echo "$OCP_EOL" | grep -Fxq "$ver"; then
    continue
  fi
  found=false
  for pv in "${POOL_VERSIONS[@]}"; do
    if [[ "$pv" == "$ver" ]]; then
      found=true
      break
    fi
  done
  if ! $found; then
    needed_by=$(echo "$RHDH_DATA" | jq -r --arg v "$ver" '[.[] | select(.supported) | select(.ocp_versions[] == $v) | .version] | join(", ")')
    echo "  ADD pool: ${ver} (needed by RHDH ${needed_by})"
    MISSING_POOL_COUNT=$((MISSING_POOL_COUNT + 1))
    HAS_ACTIONS=true
  fi
done <<< "$RHDH_ALL_OCP"
if [[ $MISSING_POOL_COUNT -eq 0 ]]; then
  echo "  (none)"
fi
echo ""

# 6e. RHDH-supported OCP versions missing test entries per branch
# Same rule: skip OCP-EOL versions.
# Iterate RHDH_BRANCH_OCP keys (not BRANCH_VERSIONS) so branches with no
# existing tests still produce ADD recommendations.
echo "--- RHDH-Supported OCP Versions Missing Tests (ADD) ---"
MISSING_TEST_COUNT=0
for branch in "${!RHDH_BRANCH_OCP[@]}"; do
  branch_rhdh_ocp="${RHDH_BRANCH_OCP[$branch]}"
  branch_existing="${BRANCH_VERSIONS[$branch]:-}"
  for ver in $branch_rhdh_ocp; do
    # Skip OCP-EOL versions — no test should be added for an EOL OCP
    if echo "$OCP_EOL" | grep -Fxq "$ver"; then
      continue
    fi
    if [[ -z "$branch_existing" ]] || ! echo "$branch_existing" | tr ' ' '\n' | grep -Fxq "$ver"; then
      echo "  ADD test: ${ver} to ${branch}"
      MISSING_TEST_COUNT=$((MISSING_TEST_COUNT + 1))
      HAS_ACTIONS=true
    fi
  done
done
if [[ $MISSING_TEST_COUNT -eq 0 ]]; then
  echo "  (none)"
fi
echo ""

# ---------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------
echo "========================================================"
echo "  Summary"
echo "========================================================"
echo ""
echo "  Pool versions:           $(printf '%s ' "${POOL_VERSIONS[@]}")"
echo "  Test versions:           $(printf '%s ' "${UNIQUE_TEST_VERSIONS[@]}")"
echo "  OCP supported:           $(echo "$OCP_SUPPORTED" | tr '\n' ' ')"
echo "  RHDH-supported OCP:      $(echo "$RHDH_SUPPORTED_OCP" | tr '\n' ' ')"
echo ""

echo "  RHDH branch -> OCP support (excluding OCP-EOL):"
for branch in $(echo "${!RHDH_BRANCH_OCP[@]}" | tr ' ' '\n' | sort); do
  # Filter out OCP-EOL versions from the display
  active_ocp=""
  eol_ocp=""
  for ver in ${RHDH_BRANCH_OCP[$branch]}; do
    if echo "$OCP_EOL" | grep -Fxq "$ver"; then
      eol_ocp="${eol_ocp} ${ver}"
    else
      active_ocp="${active_ocp} ${ver}"
    fi
  done
  line="    ${branch}:${active_ocp}"
  if [[ -n "${eol_ocp}" ]]; then
    line="${line}  (RHDH lists but OCP-EOL:${eol_ocp})"
  fi
  echo "$line"
done
echo ""

echo "  EOL pools to remove:         ${EOL_POOL_COUNT}"
echo "  Non-RHDH pools to review:    ${NOTRHDH_POOL_COUNT}"
echo "  Mismatched tests to review:  ${MISMATCH_TEST_COUNT}"
echo "  Missing pools to add:        ${MISSING_POOL_COUNT}"
echo "  Missing tests to add:        ${MISSING_TEST_COUNT}"
echo ""

if $HAS_ACTIONS; then
  echo "  Data sources:"
  echo "    RHDH lifecycle: https://access.redhat.com/support/policy/updates/developerhub"
  echo "    OCP lifecycle:  https://access.redhat.com/product-life-cycles/?product=OpenShift+Container+Platform+4"
  echo ""
  echo "  NOTE: The 'main' branch targets the next unreleased RHDH version."
  echo "  Its OCP support is estimated as: latest RHDH release's OCP list"
  echo "  plus any newer OCP versions that have reached GA."
  echo "  REVIEW items require judgment; REMOVE/ADD items are actionable."
else
  echo "  All clear -- no coverage gaps or stale configurations found."
fi
