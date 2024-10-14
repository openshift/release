#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


trap 'FRC=$?; createDowngradeJunit; debug' EXIT TERM

# Print cv, failed node, co, mcp information for debug purpose
function debug() {
    if (( FRC != 0 )); then
        oc get clusterversion/version -oyaml
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | xargs -I{} bash -c "echo -e '\n#####oc describe node {}#####\n'; oc describe node {}"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | xargs -I{} bash -c "echo -e '\n#####oc describe co {}#####\n'; oc describe co {}"
    fi
}

# Generate the Junit for downgrade
function createDowngradeJunit() {
    echo "Generating the Junit for downgrade"
    if (( FRC == 0 )); then
      cat >"${ARTIFACT_DIR}/junit_downgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster downgrade" tests="1" failures="0">
  <testcase classname="cluster downgrade" name="downgrade should succeed"/>
</testsuite>
EOF
    else
      cat >"${ARTIFACT_DIR}/junit_downgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster downgrade" tests="1" failures="1">
  <testcase classname="cluster downgrade" name="downgrade should succeed">
    <failure message="">openshift cluster downgrade failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

function check_node() {
    local node_number ready_number
    node_number=$(oc get node --no-headers | grep -cv STATUS)
    ready_number=$(oc get node --no-headers | awk '$2 == "Ready"' | wc -l)
    if (( node_number == ready_number )); then
        echo "All nodes status check PASSED"
        return 0
    else
        if (( ready_number == 0 )); then
            echo >&2 "No any ready node"
        else
            echo >&2 "We found failed node"
            oc get node --no-headers | awk '$2 != "Ready"'
        fi
        return 1
    fi
}

function check_pod() {
    echo "Show all pods status for reference/debug"
    oc get pods --all-namespaces
}

function health_check() {
    echo "Step #1: Check all cluster operators get stable and ready"
    timeout 900s bash <<EOT
until
  oc wait clusteroperators --all --for='condition=Available=True' --timeout=30s && \
  oc wait clusteroperators --all --for='condition=Progressing=False' --timeout=30s && \
  oc wait clusteroperators --all --for='condition=Degraded=False' --timeout=30s;
do
  sleep 30 && echo "Cluster Operators Degraded=True,Progressing=True,or Available=False";
done
EOT
    oc wait clusterversion/version --for='condition=Available=True' --timeout=15m

    echo "Step #2: Make sure every machine is in 'Ready' status"
    check_node

    echo "Step #3: Check all pods are in status running or complete"
    check_pod
}

if [ ! -f "${SHARED_DIR}/mgmt_kubeconfig" ]; then
    exit 1
fi
echo "switch kubeconfig"
export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"

# Setup proxy if it's present in the shared dir
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "OPENSHIFT_DOWNGRADE_RELEASE_IMAGE_OVERRIDE: $OPENSHIFT_DOWNGRADE_RELEASE_IMAGE_OVERRIDE"
cluster_name=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

echo "Compare MAIN version"
set -x
TARGET_VERSION="$(oc adm release info "${OPENSHIFT_DOWNGRADE_RELEASE_IMAGE_OVERRIDE}" -ojsonpath='{.metadata.version}')"
TARGET_MAIN_VERSION="$(echo "$TARGET_VERSION" | cut -d '.' -f 1-2)"
SOURCE_MAIN_VERSION="$(KUBECONFIG="${SHARED_DIR}/kubeconfig" oc get clusterversion --no-headers | awk '{print $2}' | cut -d '.' -f 1-2)"
echo "TARGET_MAIN_VERSION: $TARGET_MAIN_VERSION, SOURCE_MAIN_VERSION:$SOURCE_MAIN_VERSION"
oc patch hostedcluster "$cluster_name" -n "$HYPERSHIFT_NAMESPACE" --type=merge -p '{"spec":{"release":{"image":"'"${OPENSHIFT_DOWNGRADE_RELEASE_IMAGE_OVERRIDE}"'"}}}'
set +x

_downgradeReady=1
for ((i=1; i<=120; i++)); do
    sleep 30
    echo "$(date) Try ${i}/120"

    current=$(oc get hostedcluster -n "$HYPERSHIFT_NAMESPACE" "$cluster_name" -o=jsonpath='{.status.version.history[0].image}')
    if [[ $current != "$OPENSHIFT_DOWNGRADE_RELEASE_IMAGE_OVERRIDE" ]]; then
        echo "Waiting for HC.status.version.history[0] to be updated"
        continue
    fi

    state=$(oc get hostedcluster -n "$HYPERSHIFT_NAMESPACE" "$cluster_name" -o=jsonpath='{.status.version.history[0].state}')
    if [[ $state != Completed ]]; then
        echo "Waiting for HC.status.version.history[0] to complete"
        continue
    fi

    echo "HyperShift HostedCluster(CP) downgrade successful"
    _downgradeReady=0
    break
done

if [ $_downgradeReady -ne 0 ]; then
    echo "HyperShift HostedCluster(CP) downgrade failed"
    exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
health_check