#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


trap 'FRC=$?; createUpgradeJunit; debug' EXIT TERM

# Print cv, failed node, co, mcp information for debug purpose
function debug() {
    if (( FRC != 0 )); then
        oc get clusterversion/version -oyaml
        oc get node --no-headers | awk '$2 != "Ready" {print $1}' | xargs -I{} bash -c "echo -e '\n#####oc describe node {}#####\n'; oc describe node {}"
        oc get co --no-headers | awk '$3 != "True" || $4 != "False" || $5 != "False" {print $1}' | xargs -I{} bash -c "echo -e '\n#####oc describe co {}#####\n'; oc describe co {}"
    fi
}

# Generate the Junit for upgrade
function createUpgradeJunit() {
    echo "Generating the Junit for upgrade"
    if (( FRC == 0 )); then
      cat >"${ARTIFACT_DIR}/junit_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster upgrade" tests="1" failures="0">
  <testcase classname="cluster upgrade" name="upgrade should succeed"/>
</testsuite>
EOF
    else
      cat >"${ARTIFACT_DIR}/junit_upgrade.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="cluster upgrade" tests="1" failures="1">
  <testcase classname="cluster upgrade" name="upgrade should succeed">
    <failure message="">openshift cluster upgrade failed</failure>
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
        echo "All nodes status Ready"
        return 0
    else
        echo "Find Not Ready worker nodes, node recreated"
        oc get no
        exit 1
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

    echo "Step #2: Check all pods are in status running or complete"
    check_pod
}

# original worker node UIDs before controlplane upgrade
initial_uids=$(oc get nodes -o jsonpath='{.items[*].metadata.uid}')
IFS=' ' read -r -a initial_array <<< "$initial_uids"
sorted_initial_uids=$(printf "%s\n" "${initial_array[@]}" | sort | tr '\n' ' ')

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

echo "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE: $OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE"
cluster_name=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')

echo "Compare MAIN version"
set -x
TARGET_VERSION="$(oc adm release info "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" -ojsonpath='{.metadata.version}')"
TARGET_MAIN_VERSION="$(echo "$TARGET_VERSION" | cut -d '.' -f 1-2)"
SOURCE_MAIN_VERSION="$(KUBECONFIG="${SHARED_DIR}/kubeconfig" oc get clusterversion --no-headers | awk '{print $2}' | cut -d '.' -f 1-2)"
echo "TARGET_MAIN_VERSION: $TARGET_MAIN_VERSION, SOURCE_MAIN_VERSION:$SOURCE_MAIN_VERSION"
oc annotate hostedcluster -n "$HYPERSHIFT_NAMESPACE" "$cluster_name" "hypershift.openshift.io/force-upgrade-to=${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" --overwrite
oc patch hostedcluster "$cluster_name" -n "$HYPERSHIFT_NAMESPACE" --type=merge -p '{"spec":{"release":{"image":"'"${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"'"}}}'

if [[ "${HYPERSHIFT_ENABLE_MULTIARCH}" == "true" ]]; then
  echo "target hc multiArch is true"
  platform=$(oc get hostedcluster "$cluster_name" -n "$HYPERSHIFT_NAMESPACE" --ignore-not-found -o=jsonpath='{.spec.platform.type}')
  if [[ "${platform}" == "AWS" ]] ; then
    oc patch hostedcluster "$cluster_name" -n "$HYPERSHIFT_NAMESPACE" --type=merge -p '{"spec":{"platform":{"aws":{"multiArch": true}}}}'
  fi
fi
set +x

_upgradeReady=1
for ((i=1; i<=120; i++)); do
    count=$(oc get hostedcluster -n "$HYPERSHIFT_NAMESPACE" "$cluster_name" -ojsonpath='{.status.version.history[?(@.image=="'"${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"'")].state}' | grep -c Completed || true)
    if [ "$count" -eq 1 ] ; then
        echo "HyperShift HostedCluster(CP) upgrade successful"
        _upgradeReady=0
        break
    fi
    echo "Try ${i}/120: HyperShift HostedCluster(CP) is not updated yet. Checking again in 30 seconds"
    sleep 30
done

# dump hc
oc get hostedcluster "$cluster_name" -n "$HYPERSHIFT_NAMESPACE" -oyaml > "${ARTIFACT_DIR}/hostedcluster.yaml"

if [ $_upgradeReady -ne 0 ]; then
    echo "HyperShift HostedCluster(CP) upgrade failed"
    exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

echo "Monitoring for node recreation for 5 minutes..."
END_TIME=$((SECONDS + 600))
while [ $SECONDS -lt $END_TIME ]; do
  check_node
  sleep 60
done

# ensure the worker node UIDs are not changed
current_uids=$(oc get nodes -o jsonpath='{.items[*].metadata.uid}')
IFS=' ' read -r -a current_array <<< "$current_uids"
sorted_current_uids=$(printf "%s\n" "${current_array[@]}" | sort | tr '\n' ' ')

# compare the worker nodes UIDs
if [ "$sorted_initial_uids" == "$sorted_current_uids" ]; then
    echo "No changes detected in node UIDs."
else
    echo "Node UIDs have changed!"
    echo "Initial UIDs: $sorted_initial_uids"
    echo "Current UIDs: $sorted_current_uids"
    exit 1
fi

health_check