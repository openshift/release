#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Post-install reconciliation for a disconnected AWS C2S/SC2S cluster that runs
# the origin conformance suite:
#
#   1. Trust the bastion mirror registry on the nodes. Release images pull fine
#      via the install-time imageContentSources/ICSP redirect, but the e2e suite
#      references images on the mirror DIRECTLY (openshift-tests
#      --from-repository <mirror>/e2e/tests). CRI-O verifies a directly
#      referenced registry's TLS cert against /etc/docker/certs.d/<host>/ca.crt,
#      which is populated only by image.config.openshift.io/cluster
#      additionalTrustedCA -- NOT by the install-config additionalTrustBundle
#      (that is Proxyonly). Without this, e2e/monitor workload images (agnhost,
#      etc.) fail with "x509: certificate signed by unknown authority" ->
#      ImagePullBackOff. Only the mirror registry CA is trusted for that host --
#      the same file ipi-conf-mirror used, selected by SELF_MANAGED_ADDITIONAL_CA.
#
#   2. Disable the default operator catalog sources. They point at
#      registry.redhat.io, which is unreachable on a disconnected cluster, so the
#      marketplace pods crash-loop for the cluster's whole lifetime
#      (KubePodNotReady). OLMv1 default ClusterCatalogs (>= 4.18) point there too.

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

function run_command() {
    local cmd="$1"
    echo "Running command: ${cmd}"
    eval "${cmd}"
}

# ---------------------------------------------------------------------------
# 1. Trust the mirror registry CA on the nodes (fixes direct e2e image pulls).
# ---------------------------------------------------------------------------
function set_mirror_registry_ca() {
    if [[ ! -f "${SHARED_DIR}/mirror_registry_url" ]]; then
        echo "No ${SHARED_DIR}/mirror_registry_url; no mirror to trust, skipping."
        return 0
    fi

    local existing
    existing=$(oc get image.config.openshift.io/cluster -o=jsonpath="{.spec.additionalTrustedCA.name}")
    if [[ "${existing}" == "registry-config" ]]; then
        echo "image.config additionalTrustedCA already set to registry-config, skipping."
        return 0
    fi

    # Trust only the mirror registry CA for this host -- the same file
    # ipi-conf-mirror selected via SELF_MANAGED_ADDITIONAL_CA. The SHARED_DIR
    # additional_trust_bundle also carries the SHIFT CA chain (for the emulated
    # AWS API, not the registry), so it is deliberately not used here.
    local ca_file
    if [[ "${SELF_MANAGED_ADDITIONAL_CA}" == "true" ]]; then
        ca_file="${CLUSTER_PROFILE_DIR}/mirror_registry_ca.crt"
    else
        ca_file="/var/run/vault/mirror-registry/client_ca.crt"
    fi
    if [[ ! -s "${ca_file}" ]]; then
        echo "${ca_file} is missing or empty; cannot trust the mirror registry."
        return 1
    fi

    local mirror host port
    mirror=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")   # <host>:<port>
    host="${mirror%%:*}"
    port="${mirror##*:}"

    # Configmap keys cannot contain ':'; the MCO maps '<host>..<port>' back to
    # /etc/docker/certs.d/<host>:<port>/ on the nodes.
    run_command "oc create configmap registry-config --from-file=\"${host}..${port}\"=\"${ca_file}\" -n openshift-config"
    run_command "oc patch image.config.openshift.io/cluster --type=merge --patch '{\"spec\":{\"additionalTrustedCA\":{\"name\":\"registry-config\"}}}'"
}

# Wait for the worker MachineConfigPool to finish applying the new trust before
# the e2e suite starts pulling e2e images from the mirror.
function wait_for_worker_mcp() {
    local machine_count updated i
    machine_count=$(oc get mcp worker -o=jsonpath='{.status.machineCount}')
    # Give the MCO a moment to notice the change and mark the pool Updating.
    sleep 30
    for (( i=0; i<1200; i+=20 )); do
        updated=$(oc get mcp worker -o=jsonpath='{.status.updatedMachineCount}')
        echo "worker MCP: ${updated}/${machine_count} updated (${i}s)"
        if [[ "${updated}" == "${machine_count}" ]]; then
            echo "worker MCP converged."
            return 0
        fi
        sleep 20
    done
    echo "!!! worker MCP did not converge in time"
    run_command "oc get mcp,node"
    return 1
}

# ---------------------------------------------------------------------------
# 2. Disable default (internet-facing) operator catalog sources.
# ---------------------------------------------------------------------------
function patch_clustercatalog_if_exists() {
    local name="$1"
    if oc get clustercatalog "${name}" >/dev/null 2>&1; then
        run_command "oc patch clustercatalog ${name} --type=merge -p '{\"spec\":{\"availabilityMode\":\"Unavailable\"}}'"
    else
        echo "clustercatalog ${name} not found, skipping."
    fi
}

function disable_default_catalogsources() {
    # OLMv0 default CatalogSources in openshift-marketplace.
    run_command "oc patch operatorhub cluster --type=merge -p '{\"spec\":{\"disableAllDefaultSources\":true}}'"

    # OLMv1 default ClusterCatalogs (>= 4.18). Guarded by existence so this is
    # safe across versions and catalog churn (e.g. redhat-marketplace removed in
    # 4.22).
    if oc get clustercatalog >/dev/null 2>&1; then
        patch_clustercatalog_if_exists openshift-certified-operators
        patch_clustercatalog_if_exists openshift-redhat-operators
        patch_clustercatalog_if_exists openshift-redhat-marketplace
        patch_clustercatalog_if_exists openshift-community-operators
    fi
}

set_mirror_registry_ca
disable_default_catalogsources
wait_for_worker_mcp
