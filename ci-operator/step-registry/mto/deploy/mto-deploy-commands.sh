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
  <testcase name="OCP-00001:lwan:Installing Multiarch Tuning Operator and ClusterPodPlacementConfig should succeed"/>
</testsuite>
EOF
    else
        cat >"${ARTIFACT_DIR}/${filename}.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="${testsuite}" failures="1" errors="0" skipped="0" tests="1" time="1">
  <testcase name="OCP-00001:lwan:Installing Multiarch Tuning Operator and ClusterPodPlacementConfig should succeed">
    <failure message="">Installing Multiarch Tuning Operator or ClusterPodPlacementConfig failed</failure>
  </testcase>
</testsuite>
EOF
    fi
}

# Deploy Multiarch Tuning Operator
# Now  we deploy it using the latest bundle images in registry.ci,
# and will change to via operatorhub when it's ready.
NAMESPACE=openshift-multiarch-tuning-operator
oc create namespace ${NAMESPACE}
OO_BUNDLE=registry.ci.openshift.org/origin/multiarch-tuning-op-bundle:main
operator-sdk run bundle --timeout=10m --security-context-config restricted -n $NAMESPACE "$OO_BUNDLE"
oc wait deployments -n ${NAMESPACE} \
  -l app.kubernetes.io/part-of=multiarch-tuning-operator \
  --for=condition=Available=True
oc wait pods -n ${NAMESPACE} \
  -l control-plane=controller-manager \
  --for=condition=Ready=True

# Deploy Pod Placement operand
oc create -f - <<EOF
apiVersion: multiarch.openshift.io/v1alpha1
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
oc wait pods -n ${NAMESPACE} \
  -l controller=pod-placement-controller \
  --for=condition=Ready=True
oc wait pods -n ${NAMESPACE} \
  -l controller=pod-placement-web-hook \
  --for=condition=Ready=True
