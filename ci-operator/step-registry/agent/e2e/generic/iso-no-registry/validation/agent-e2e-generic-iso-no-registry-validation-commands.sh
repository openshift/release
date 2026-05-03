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
        return 0

        oc get clusterversion --no-headers || true
        sleep "$sleep_seconds"
    done

    echo "ERROR: cluster not available after 60 minutes."
    return 1
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

if ! command -v oc >/dev/null 2>&1 && [ -x /cli/oc ]; then
  export PATH="/cli:${PATH}"
fi

wait_for_cluster_available
verify_installed_operators

echo "Cluster and operators installed successfully!"
