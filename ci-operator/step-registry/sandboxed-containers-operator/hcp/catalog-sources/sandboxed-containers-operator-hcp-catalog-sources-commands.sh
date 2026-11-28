#!/bin/bash

set -euo pipefail
# No -x: the sourced environment carries credential paths; command tracing
# would leak them into the CI log.

echo "=========================================="
echo "OSC HCP :: catalog sources (management -> hosted)"
echo "=========================================="

HCP_ENV="${SHARED_DIR}/hcp/env.sh"
if [[ ! -f "${HCP_ENV}" ]]; then
    echo "ERROR: ${HCP_ENV} not found - the hcp-conf-aws step did not run"
    exit 1
fi
# shellcheck disable=SC1090
source "${HCP_ENV}"
# shellcheck disable=SC1090
source "${SHARED_DIR}/hcp/state.sh"

HOSTED_KUBECONFIG="${SHARED_DIR}/kubeconfig"
MGMT_KUBECONFIG="${HCP_MGMT_KUBECONFIG}"

command -v oc >/dev/null 2>&1 || { echo "ERROR: oc not found in the step image"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq not found in the step image"; exit 1; }

# Hosted clusters do not inherit the default OperatorHub catalogs; without
# them the OLM subscription never resolves. Copy the four default GA catalogs
# from the management cluster, stripping the master nodeSelector and
# tolerations (hosted clusters have no masters). The custom Pre-GA catalog is
# a different thing, created by install-osc-operator via dev.enabled=true;
# the two do not overlap.
CATALOGS=(redhat-operators certified-operators community-operators redhat-marketplace)

for cs in "${CATALOGS[@]}"; do
    if KUBECONFIG="${HOSTED_KUBECONFIG}" oc get catalogsource "${cs}" -n openshift-marketplace >/dev/null 2>&1; then
        echo ">>> CatalogSource already exists: ${cs}"
        continue
    fi
    json="$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get catalogsource "${cs}" -n openshift-marketplace -o json 2>/dev/null || true)"
    if [[ -z "${json}" ]]; then
        echo ">>> WARNING: could not fetch CatalogSource ${cs} from the management cluster"
        continue
    fi
    echo ">>> Copying CatalogSource: ${cs}"
    echo "${json}" | \
        jq 'del(.metadata.resourceVersion,.metadata.uid,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields,.status) |
            del(.spec.grpcPodConfig.nodeSelector."node-role.kubernetes.io/master") |
            .spec.grpcPodConfig.tolerations |= if . then map(select(.key != "node-role.kubernetes.io/master")) else . end' | \
        KUBECONFIG="${HOSTED_KUBECONFIG}" oc apply -f - || \
        echo ">>> WARNING: could not copy CatalogSource: ${cs}"
done

# Delete catalog pods stuck in image pull backoff so they restart immediately
# with the current pull secret rather than waiting out exponential backoff.
stuck_pods="$(KUBECONFIG="${HOSTED_KUBECONFIG}" oc get pods -n openshift-marketplace --no-headers 2>/dev/null | \
    awk '$3 ~ /ImagePullBackOff|ErrImagePull/ {print $1}')"
if [[ -n "${stuck_pods}" ]]; then
    echo ">>> Deleting stuck catalog pods (ImagePullBackOff): ${stuck_pods}"
    # shellcheck disable=SC2086
    KUBECONFIG="${HOSTED_KUBECONFIG}" oc delete pod -n openshift-marketplace --ignore-not-found ${stuck_pods} >/dev/null
    echo ">>> CatalogSource controller will recreate them"
fi

echo ">>> Catalog sources ready on the hosted cluster"
