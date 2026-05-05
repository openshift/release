#!/usr/bin/env bash
# Inspect the RHDH long-running GKE cluster (read-only).
#
# Auto-discovers the cluster name and project from gcloud by listing clusters
# in the default project. Overrides are available via flags.
#
# When upgrades are available, prints a direct link to the GCP Console to
# perform the upgrade manually.
#
# Usage:
#   inspect-gke-cluster.sh [OPTIONS]
#
# Options:
#   --project <id>    GCP project  (default: auto-detected from gcloud config)
#   --cluster <name>  Cluster name (default: auto-detected, first cluster in project)
#   --zone    <zone>  Compute zone (default: auto-detected from cluster location)
#
# This script never mutates the cluster.
#
# Requires: gcloud (authenticated), curl, jq

set -euo pipefail

# ── Defaults (auto-detect) ────────────────────────────────────────────────────
PROJECT=""
CLUSTER=""
ZONE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --zone)    ZONE="$2"; shift 2 ;;
    *) echo "Usage: $0 [--project <id>] [--cluster <name>] [--zone <zone>]" >&2; exit 1 ;;
  esac
done

# ── Pre-flight checks ────────────────────────────────────────────────────────
command -v gcloud &>/dev/null || { echo "ERROR: gcloud CLI is required" >&2; exit 1; }
command -v jq    &>/dev/null || { echo "ERROR: jq is required" >&2; exit 1; }
command -v curl  &>/dev/null || { echo "ERROR: curl is required" >&2; exit 1; }

# ── Auto-detect project ──────────────────────────────────────────────────────
if [[ -z "${PROJECT}" ]]; then
  PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -z "${PROJECT}" ]]; then
    echo "ERROR: No GCP project configured. Use --project or run: gcloud config set project <id>" >&2
    exit 1
  fi
fi

# ── Auto-detect cluster ──────────────────────────────────────────────────────
if [[ -z "${CLUSTER}" ]]; then
  CLUSTER_LIST=$(gcloud container clusters list --project "${PROJECT}" \
    --format='value(name,location)' 2>/dev/null) || true

  if [[ -z "${CLUSTER_LIST}" ]]; then
    echo "ERROR: No GKE clusters found in project ${PROJECT}" >&2
    exit 1
  fi

  CLUSTER_COUNT=$(echo "${CLUSTER_LIST}" | wc -l | tr -d ' ')
  if [[ "${CLUSTER_COUNT}" -gt 1 ]]; then
    echo "Multiple clusters found in project ${PROJECT}:" >&2
    echo "${CLUSTER_LIST}" | while IFS=$'\t' read -r name loc; do
      echo "  ${name} (${loc})" >&2
    done
    echo "Use --cluster <name> to select one." >&2
    exit 1
  fi

  CLUSTER=$(echo "${CLUSTER_LIST}" | awk '{print $1}')
  DETECTED_ZONE=$(echo "${CLUSTER_LIST}" | awk '{print $2}')
  if [[ -z "${ZONE}" ]]; then
    ZONE="${DETECTED_ZONE}"
  fi
fi

if [[ -z "${ZONE}" ]]; then
  echo "ERROR: Could not detect zone. Use --zone <zone>" >&2
  exit 1
fi

echo "Cluster : ${CLUSTER}"
echo "Project : ${PROJECT}"
echo "Zone    : ${ZONE}"
echo ""

# ── Current cluster version ───────────────────────────────────────────────────
echo "=== Current Cluster Version ==="
CLUSTER_JSON=$(gcloud container clusters describe "${CLUSTER}" \
  --zone "${ZONE}" --project "${PROJECT}" \
  --format='json(currentMasterVersion,currentNodeVersion,releaseChannel,nodePools[].name,nodePools[].version)' 2>&1) \
  || { echo "ERROR: Cannot describe cluster. Check gcloud auth and project." >&2; echo "${CLUSTER_JSON}" >&2; exit 1; }

MASTER_VER=$(echo "${CLUSTER_JSON}" | jq -r '.currentMasterVersion')
NODE_VER=$(echo "${CLUSTER_JSON}" | jq -r '.currentNodeVersion')
CHANNEL=$(echo "${CLUSTER_JSON}" | jq -r '.releaseChannel.channel // "UNSPECIFIED"')
CURRENT_MINOR=$(echo "${MASTER_VER}" | cut -d. -f1-2)

echo "  Master version : ${MASTER_VER}"
echo "  Node version   : ${NODE_VER}"
echo "  Release channel: ${CHANNEL}"

# Print per-pool versions
POOL_COUNT=$(echo "${CLUSTER_JSON}" | jq '.nodePools | length')
if [[ "${POOL_COUNT}" -gt 0 ]]; then
  echo "  Node pools:"
  echo "${CLUSTER_JSON}" | jq -r '.nodePools[] | "    \(.name): \(.version)"'
fi
echo ""

# ── Available versions from server config ─────────────────────────────────────
echo "=== Available Versions (gcloud get-server-config) ==="
SERVER_CFG=$(gcloud container get-server-config \
  --zone "${ZONE}" --project "${PROJECT}" --format=json 2>/dev/null) \
  || { echo "ERROR: Cannot fetch server config" >&2; exit 1; }

VALID_MASTERS=$(echo "${SERVER_CFG}" | jq -r '.validMasterVersions[]' | sort -V)
VALID_MINORS=$(echo "${VALID_MASTERS}" | cut -d. -f1-2 | sort -uV)
VALID_NODES=$(echo "${SERVER_CFG}" | jq -r '.validNodeVersions[]' | sort -V)

# Latest patch for the current minor
LATEST_CURRENT_PATCH=$(echo "${VALID_MASTERS}" | grep "^${CURRENT_MINOR}\." | tail -1 || true)
LATEST_NODE_PATCH=$(echo "${VALID_NODES}" | grep "^${CURRENT_MINOR}\." | tail -1 || true)

echo "  Available minor versions:"
for minor in ${VALID_MINORS}; do
  latest=$(echo "${VALID_MASTERS}" | grep "^${minor}\." | tail -1)
  if [[ "${minor}" == "${CURRENT_MINOR}" ]]; then
    echo "    ${minor}  (latest patch: ${latest})  <-- current"
  else
    echo "    ${minor}  (latest patch: ${latest})"
  fi
done
echo ""

# ── Endoflife.date cross-check ────────────────────────────────────────────────
echo "=== Lifecycle Status (endoflife.date) ==="
TODAY=$(date -u +%Y-%m-%d)
EOL_DATA=$(curl -s --fail "https://endoflife.date/api/google-kubernetes-engine.json" 2>/dev/null) || true

if [[ -n "${EOL_DATA}" ]]; then
  echo "${EOL_DATA}" | jq -r --arg t "${TODAY}" --arg cur "${CURRENT_MINOR}" '
    .[] |
    (.eol // "N/A") as $eol |
    (if $eol == "N/A" then true elif ($eol | type) == "boolean" then ($eol | not) else $eol > $t end) as $supported |
    select($supported) |
    (.support // "N/A") as $support |
    (if $support == "N/A" then "Unknown"
     elif ($support | type) == "boolean" then "Unknown"
     elif $support > $t then "Standard"
     else "Maintenance" end) as $status |
    "  \(.cycle)  \($status)  EOL: \($eol)\(if .cycle == $cur then "  <-- current" else "" end)"
  '
else
  echo "  WARNING: Could not fetch endoflife.date data"
fi
echo ""

# ── Check for available upgrades ──────────────────────────────────────────────
MASTER_UPGRADABLE=false
NODE_UPGRADABLE=false

if [[ -n "${LATEST_CURRENT_PATCH}" && "${MASTER_VER}" != "${LATEST_CURRENT_PATCH}" ]]; then
  MASTER_UPGRADABLE=true
fi

POOL_NAMES=$(echo "${CLUSTER_JSON}" | jq -r '.nodePools[].name')
for pool in ${POOL_NAMES}; do
  POOL_VER=$(echo "${CLUSTER_JSON}" | jq -r --arg p "${pool}" '.nodePools[] | select(.name == $p) | .version')
  if [[ -n "${LATEST_NODE_PATCH}" && "${POOL_VER}" != "${LATEST_NODE_PATCH}" ]]; then
    NODE_UPGRADABLE=true
    break
  fi
done

# Check for newer minor versions
NEWEST_MINOR=$(echo "${VALID_MINORS}" | tail -1)
MINOR_UPGRADE_AVAILABLE=false
if [[ "${NEWEST_MINOR}" != "${CURRENT_MINOR}" ]]; then
  MINOR_UPGRADE_AVAILABLE=true
fi

if [[ "${MASTER_UPGRADABLE}" == true || "${NODE_UPGRADABLE}" == true || "${MINOR_UPGRADE_AVAILABLE}" == true ]]; then
  echo "=== Upgrade Available ==="

  if [[ "${MASTER_UPGRADABLE}" == true ]]; then
    echo "  Master patch upgrade : ${MASTER_VER} -> ${LATEST_CURRENT_PATCH}"
  fi

  for pool in ${POOL_NAMES}; do
    POOL_VER=$(echo "${CLUSTER_JSON}" | jq -r --arg p "${pool}" '.nodePools[] | select(.name == $p) | .version')
    if [[ -n "${LATEST_NODE_PATCH}" && "${POOL_VER}" != "${LATEST_NODE_PATCH}" ]]; then
      echo "  Pool '${pool}' patch  : ${POOL_VER} -> ${LATEST_NODE_PATCH}"
    fi
  done

  if [[ "${MINOR_UPGRADE_AVAILABLE}" == true ]]; then
    NEWEST_PATCH=$(echo "${VALID_MASTERS}" | grep "^${NEWEST_MINOR}\." | tail -1)
    echo "  Minor version upgrade: ${CURRENT_MINOR} -> ${NEWEST_MINOR} (latest patch: ${NEWEST_PATCH})"
  fi

  CONSOLE_URL="https://console.cloud.google.com/kubernetes/clusters/details/${ZONE}/${CLUSTER}/details?project=${PROJECT}"

  echo ""
  echo "  To upgrade, open the GCP Console:"
  echo "  ${CONSOLE_URL}"
else
  echo "=== Cluster is fully up to date ==="
  echo "  No upgrades available for ${CURRENT_MINOR}."
fi
