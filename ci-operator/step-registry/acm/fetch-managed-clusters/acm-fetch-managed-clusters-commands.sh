#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail


# The variables defined in this step come from files in the `SHARED_DIR` and credentials from Vault.
SECRETS_DIR="/tmp/secrets"

# Get the creds from ACMQE CI vault and run the automation on pre-exisiting HUB
SKIP_OCP_DEPLOY="false"
if [[ $SKIP_OCP_DEPLOY == "true" ]]; then
    echo "------------ Skipping OCP Deploy = $SKIP_OCP_DEPLOY ------------"
    cp ${SECRETS_DIR}/ci/kubeconfig $SHARED_DIR/kubeconfig
    cp ${SECRETS_DIR}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
fi   

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Set the dynamic vars based on provisioned hub cluster.
HUB_OCP_API_URL=$(oc whoami --show-server)
export HUB_OCP_API_URL
HUB_OCP_PASSWORD=$(cat $SHARED_DIR/kubeadmin-password)
export HUB_OCP_PASSWORD

# ── Pre-flight: check CLC smoke JUnit contract ────────────────────────
# The CLC smoke step propagates JUnit XML files to ${SHARED_DIR}/junit/
# via its EXIT handler.  If any report contains <failure or <error elements
# the managed-cluster fetch would operate on a broken cluster.
typeset junitDir="${SHARED_DIR}/junit"
if [[ -d "${junitDir}" ]]; then
    typeset -i junitFails=0
    while IFS= read -r -d '' xmlFile; do
        if grep -qE '<failure|<error' "${xmlFile}"; then
            echo "WARNING: JUnit failure found in ${xmlFile}" 1>&2
            junitFails+=1
        fi
    done < <(find "${junitDir}" -name 'junit*.xml' -print0 2>/dev/null)

    if (( junitFails > 0 )); then
        echo "CLC smoke step reported JUnit failures; skipping managed-cluster fetch" 1>&2
        exit 1
    fi
fi

# ── Readiness wait: ManagedCluster Available ──────────────────────────
# Wait for the managed cluster to become available before fetching data.
if [ -s /tmp/ci/managed.cluster.name ] && ! grep -q "null" /tmp/ci/managed.cluster.name; then
    typeset mcName
    mcName="$(cat /tmp/ci/managed.cluster.name)"
    echo "Waiting up to 10m for ManagedCluster/${mcName} to reach Available=True ..."
    typeset waitErr
    if ! waitErr=$(oc wait "managedcluster/${mcName}" \
            --for=condition=ManagedClusterConditionAvailable \
            --timeout=10m 2>&1); then
        echo "ERROR: ManagedCluster/${mcName} did not become Available within 10m" 1>&2
        [[ -n "${waitErr}" ]] && echo "  oc-wait: ${waitErr}" 1>&2
        if command -v jq &>/dev/null; then
            oc get "managedcluster/${mcName}" \
                -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")]}' | \
                jq -r '"  status=\(.status)  reason=\(.reason // "n/a")  message=\(.message // "n/a")"' || \
                echo "  (could not retrieve condition details)" 1>&2
        else
            echo "  (jq not available; falling back to oc get -o yaml)" 1>&2
            oc get "managedcluster/${mcName}" -o yaml || \
                echo "  (could not retrieve condition details)" 1>&2
        fi
        exit 1
    fi
    echo "ManagedCluster/${mcName} is Available."
else
    echo "ERROR: /tmp/ci/managed.cluster.name is missing, empty, or contains 'null'." 1>&2
    if [ -f /tmp/ci/managed.cluster.name ]; then
        echo "  File content: $(cat /tmp/ci/managed.cluster.name)" 1>&2
    else
        echo "  File does not exist." 1>&2
    fi
    echo "  The CLC smoke step likely failed to provision a managed cluster." 1>&2
    echo "  Check the clc-smoke step artifacts (under artifacts/clc-smoke/) for details." 1>&2
    exit 1
fi

# run the test execution script
./fetch_clusters_commands.sh

if [ -s /tmp/ci/managed.cluster.name ] && ! grep -q "null" /tmp/ci/managed.cluster.name; then
    echo "managed.cluster.name file was found saving as artifact."
    cp -r /tmp/ci/managed.cluster.name $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.base.domain $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.api.url $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.username $SHARED_DIR/
    cp -r /tmp/ci/managed.cluster.password $SHARED_DIR/
else
    echo "managed.cluster.name file is empty, missing, or it contains null."
    echo "Failed to fetch managed clusters, killing job."
    exit 1
fi
