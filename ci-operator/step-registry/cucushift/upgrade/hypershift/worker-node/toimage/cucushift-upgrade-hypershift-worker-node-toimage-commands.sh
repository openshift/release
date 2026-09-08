#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

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

echo "OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE: $OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE"
cluster_name=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
echo "hostedclusters => ns: $HYPERSHIFT_NAMESPACE , cluster_namename: $cluster_name"

NodePoolList=$(oc get nodepool -n "$HYPERSHIFT_NAMESPACE" -ojsonpath='{.items[?(@.spec.clusterName=="'"${cluster_name}"'")].metadata.name}' | tr ' ' '\n')
NodePoolArr=()
while read -r NodePool; do
  NodePoolArr+=("$NodePool")
done <<< "$NodePoolList"

echo "${NodePoolArr[@]}"
for NodePool in "${NodePoolArr[@]}"
do
    oc patch nodepool "$NodePool" -n "$HYPERSHIFT_NAMESPACE" --type=merge -p '{"spec":{"nodeDrainTimeout":"60s","release":{"image":"'"${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}"'"}}}'
done

TARGET_VERSION="$(oc adm release info "${OPENSHIFT_UPGRADE_RELEASE_IMAGE_OVERRIDE}" -ojsonpath='{.metadata.version}')"
_upgradeReady=0
for ((i=1; i<=120; i++)); do
    _upgradeReady=0
    for NodePool in "${NodePoolArr[@]}"
    do
        version=$(oc get nodepool "$NodePool" -n "$HYPERSHIFT_NAMESPACE" -ojsonpath="{.status.version}")
        if [[ "$version" == "$TARGET_VERSION" ]]; then
            _upgradeReady=$(( _upgradeReady + 1 ))
        fi
    done
    if [[ "$_upgradeReady" -eq "${#NodePoolArr[@]}" ]] ; then
        echo "upgrade NodePool(worker node) successful"
        break
    fi
    echo "Try ${i}/120: HyperShift NodePool(worker node) is not updated yet. Checking again in 30 seconds"
    sleep 60
done

if [[ "$_upgradeReady" -ne "${#NodePoolArr[@]}" ]]; then
    echo "HyperShift NodePool(worker node) upgrade failed"
    exit 1
fi

oc wait nodepool -n "$HYPERSHIFT_NAMESPACE" --for=condition=AllMachinesReady --all --timeout=15m
oc wait nodepool -n "$HYPERSHIFT_NAMESPACE" --for=condition=AllNodesHealthy --all --timeout=15m

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
health_check

#check 4.18 container runtime
TARGET_MAIN_VERSION="$(echo "$TARGET_VERSION" | cut -d '.' -f 1-2)"
if (( $(awk 'BEGIN {print ("'"$TARGET_MAIN_VERSION"'" >= 4.18)}') )); then
  while read -r name _ _ _; do
    runtime=$(oc debug node/"${name}" -- chroot /host bash -c 'cat /etc/crio/crio.conf.d/00-default' | grep runtime)
    echo "$runtime"
    if [[ "$runtime" != *"crun"* ]]; then
      echo "runtime is not crun"
      exit 1
    fi
  done < <(oc get node --no-headers)
fi