#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function wait_for_cluster_available() {
    local attempts=120
    local sleep_seconds=30
    local i

    echo "Waiting for cluster available..."
    oc get clusterversion || true

    for ((i=0; i<attempts; i++)); do
        oc wait clusterversion version --for=condition=Available=True --timeout=1s 2>/dev/null && 
        oc wait clusterversion version --for=condition=Progressing=False --timeout=1s 2>/dev/null &&
        oc wait clusterversion version --for=condition=Failing=False --timeout=1s 2>/dev/null &&
        break

        oc get clusterversion --no-headers || true
        sleep "$sleep_seconds"
    done

    if [ "$i" -ge "$attempts" ]; then
        echo "ERROR: cluster not available after 60 minutes."
        return 1
    fi

    # Ensure all cluster operators remain stable for a sustained period
    # to avoid flaky results from transient operator restarts
    oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=105m
}

function verify_installed_operators() {
    local attempts=120
    local sleep_seconds=30
    local csvs
    local not_succeeded
    local i

    echo "Checking installed operators..."

    for ((i=0; i<attempts; i++)); do
        # Check if there are some ClusterServiceVersion resources
        if ! csvs="$(oc get csv -A --no-headers 2>/dev/null)"; then
            echo "WARN: failed to get ClusterServiceVersions, retrying..."
            sleep "$sleep_seconds"
            continue
        fi

        if [ -z "$csvs" ]; then
            echo "WARN: no ClusterServiceVersions found yet, retrying..."
            sleep "$sleep_seconds"
            continue
        fi

        not_succeeded="$(grep -v Succeeded <<<"$csvs" || true)"
        if [ -n "$not_succeeded" ]; then
            echo "CSVs not yet all Succeeded, retrying..."
            echo "$not_succeeded"
            sleep "$sleep_seconds"
            continue
        fi

        echo "Operators installed successfully!"
        return 0
    done

    echo "ERROR: some operators did not reach Succeeded state in time"
    oc get csv -A || true
    return 1
}

function rendered_mc_fips() {
    local pool="$1"
    local rendered
    local fips

    if ! rendered="$(oc get mcp "$pool" -o jsonpath='{.status.configuration.name}' 2>/dev/null)" || [ -z "$rendered" ]; then
        echo "ERROR: ${pool} MachineConfigPool has no rendered configuration" >&2
        return 1
    fi

    if ! fips="$(oc get mc "$rendered" -o jsonpath='{.spec.fips}' 2>/dev/null)"; then
        echo "ERROR: failed to read rendered MachineConfig ${rendered} for the ${pool} pool" >&2
        return 1
    fi

    echo "${fips:-false}"
}

function verify_fips() {
    local expected="${FIPS_MODE:-false}"
    local install_config
    local requested
    local pool
    local actual

    echo "Checking FIPS state (job requested FIPS: ${expected})..."

    # An unreadable install-config is an error rather than a missing fips
    # setting, which would let a FIPS cluster pass unverified.
    if ! install_config="$(oc get cm -n kube-system cluster-config-v1 -o jsonpath='{.data.install-config}' 2>/dev/null)" ||
        [ -z "$install_config" ]; then
        echo "ERROR: could not read install-config from the cluster-config-v1 ConfigMap"
        return 1
    fi

    # install-config omits fips entirely when it is false.
    if grep -qE '^[[:space:]]*"?fips"?:[[:space:]]*true' <<<"$install_config"; then
        requested=true
    else
        requested=false
    fi

    if [ "$requested" != "$expected" ]; then
        echo "ERROR: the job requested FIPS=${expected} but the cluster was installed with fips=${requested}"
        echo "The FIPS setting did not reach install-config."
        return 1
    fi

    # Rendered MachineConfig per pool, the same check openshift/installer#10348
    # performs after an agent install.
    for pool in master worker; do
        if ! actual="$(rendered_mc_fips "$pool")"; then
            return 1
        fi

        if [ "$actual" != "$expected" ]; then
            echo "ERROR: rendered MachineConfig for the ${pool} pool has fips=${actual}, expected ${expected}"
            return 1
        fi

        echo "  ${pool} pool: fips=${actual}"
    done

    echo "FIPS state matches the job configuration!"
}

if ! command -v oc >/dev/null 2>&1 && [ -x /cli/oc ]; then
  export PATH="/cli:${PATH}"
fi

wait_for_cluster_available
verify_installed_operators
verify_fips

echo "Cluster and operators installed successfully!"
