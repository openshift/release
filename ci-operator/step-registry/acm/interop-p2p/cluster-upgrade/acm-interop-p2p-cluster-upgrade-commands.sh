#!/bin/bash
#
# Upgrades the hub cluster to the latest RC image resolved from ORIGINAL_RELEASE_IMAGE_LATEST.
# Patches TARGET_CHANNEL, then initiates and waits for the clusterversion upgrade to complete.
#
set -euxo pipefail; shopt -s inherit_errexit

# [[ -n ]] guards against empty jq output (missing field returns ""; jq exits 0 so set -e alone is insufficient).
typeset targetVersion
targetVersion="$(oc adm release info "${ORIGINAL_RELEASE_IMAGE_LATEST}" -o json | jq -r '.metadata.version')"
[[ -n "${targetVersion}" ]]

typeset digest
digest="$(oc adm release info "${ORIGINAL_RELEASE_IMAGE_LATEST}" -o json | jq -r '.digest')"
[[ -n "${digest}" ]]

typeset imgRepo="${ORIGINAL_RELEASE_IMAGE_LATEST%:*}"

# Patch channel; KUBECONFIG is set by CI Operator to the hub cluster.
oc patch clusterversion version --type merge \
    -p "$(jq -cn --arg ch "${TARGET_CHANNEL}" '{"spec":{"channel":$ch}}')"

# Initiate the upgrade.
oc adm upgrade \
    --to-image="${imgRepo}@${digest}" \
    --allow-explicit-upgrade \
    --allow-upgrade-with-warnings \
    --force

# Wait for the upgrade: first confirm targetVersion appears in history, then confirm Completed.
# Two oc wait calls are needed because oc wait supports only one jsonpath condition each.
oc wait clusterversion/version \
    --for=jsonpath='{.status.history[0].version}'="${targetVersion}" \
    --timeout="${ACM_UPGRADE_TIMEOUT_SECONDS}s"

oc wait clusterversion/version \
    --for=jsonpath='{.status.history[0].state}'="Completed" \
    --timeout=10m

echo "[SUCCESS] Hub cluster upgraded to ${targetVersion}"
# Cluster health check runs in the next step (cucushift-installer-check-cluster-health).
