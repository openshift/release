#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

trap 'FRC=$?; createMTOJunit; debug' EXIT TERM

# Print deployments, pods, nodes for debug purpose
function debug() {
    if (( FRC != 0 )); then
        echo -e "Getting deployment info...\n"
        echo -e "oc -n $NAMESPACE get deployments -owide\n$(oc -n $NAMESPACE get deployments -owide)"
        echo -e "Getting pod info....\n"
        echo -e "oc -n $NAMESPACE get pods -owide\n$(oc -n $NAMESPACE get pods -owide)"
        echo -e "Getting nodes info...\n"
        echo -e "oc get node -owide\n$(oc get node -owide)"
    fi
}

# Generate the Junit for MTO
function createMTOJunit() {
    echo "Generating the Junit for MTO"
    filename="import-MTO"
    testsuite="MTO"
    if (( FRC == 0 )); then
        cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="0" errors="0" skipped="0" tests="1" time="1">
  <testcase name="OCP-00002:lwan:Installing Cluster PodPlacement Config operand should succeed"/>
</testsuite>
EOF
    else
        cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="1">
  <testcase name="OCP-00002:lwan:Installing Cluster PodPlacement Config operand should succeed">
    <failure message="">Installing Cluster PodPlacement Config operand failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

function wait_created() {
    # wait 10 mins
    for _ in $(seq 1 60); do
        if oc get "${@}" | grep -v -q "No resources found"; then
            return 0
        fi
        sleep 10
    done
    return 1
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    echo "Setting proxy"
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Deploy Pod Placement operand
if [[ "$MTO_POD_PLACEMENT_API_VERSION" != "v1beta1" && "$MTO_POD_PLACEMENT_API_VERSION" != "v1alpha1" ]]; then
  echo "MTO_POD_PLACEMENT_API_VERSION must be either v1beta1 or v1alpha1, current value is $MTO_POD_PLACEMENT_API_VERSION"
  exit 1
fi
echo "Deploying ${MTO_POD_PLACEMENT_API_VERSION} version ClusterPodPlacementConfig"
oc create -f - <<EOF
apiVersion: multiarch.openshift.io/${MTO_POD_PLACEMENT_API_VERSION}
kind: ClusterPodPlacementConfig
metadata:
  name: cluster
spec:
  logVerbosityLevel: Normal
  namespaceSelector:
    matchExpressions:
      - key: multiarch.openshift.io/exclude-pod-placement
        operator: DoesNotExist
EOF
echo "Get ClusterPodPlacementConfig"
oc get clusterpodplacementConfig cluster -oyaml
echo "Waiting for operand to be ready"
oc get pods -n openshift-multiarch-tuning-operator
echo "Waiting for pod-placement-controller"
wait_created pods -n openshift-multiarch-tuning-operator -l controller=pod-placement-controller
oc get pods -n openshift-multiarch-tuning-operator -l controller=pod-placement-controller
oc wait pods --timeout=300s -n openshift-multiarch-tuning-operator -l controller=pod-placement-controller --for=condition=Ready=True
echo "Waiting for pod-placement-web-hook"
wait_created pods -n openshift-multiarch-tuning-operator -l controller=pod-placement-web-hook
oc get pods -n openshift-multiarch-tuning-operator -l controller=pod-placement-web-hook
oc wait pods --timeout=300s -n openshift-multiarch-tuning-operator -l controller=pod-placement-web-hook --for=condition=Ready=True
echo "The operand is ready"
oc get pods -n openshift-multiarch-tuning-operator
