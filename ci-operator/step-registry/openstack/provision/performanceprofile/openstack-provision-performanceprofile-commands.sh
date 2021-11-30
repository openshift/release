#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if test -f "${SHARED_DIR}/shiftstack-ci-functions.sh"
    source "${SHARED_DIR}/shiftstack-ci-functions.sh"
then
    echo "Warning: failed to find ${SHARED_DIR}/shiftstack-ci-functions.sh!"
    CO_DIR=$(mktemp -d)
    echo "Falling back to local copy in ${CO_DIR}"
    git clone https://github.com/shiftstack/shiftstack-ci.git "${CO_DIR}"
    if test -f "${CO_DIR}/shiftstack-ci-functions.sh"
    then
        source "${CO_DIR}/shiftstack-ci-functions.sh"
    else
        echo "Failed to find ${CO_DIR}/shiftstack-ci-functions.sh!"
    fi
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

HUGEPAGES="${HUGEPAGES:-1}"
CPU_ISOLATED="${CPU_ISOLATED:-2-7}"
CPU_RESERVED="${CPU_RESERVED:-0-1}"

PAO_NAMESPACE=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-performance-addon-operator
  annotations:
    workload.openshift.io/allowed: management
EOF
)
echo "Created \"$PAO_NAMESPACE\" Namespace"

PAO_OPERATORGROUP=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-performance-addon-operator
  namespace: openshift-performance-addon-operator
EOF
)
echo "Created \"$PAO_OPERATORGROUP\" OperatorGroup"

channel=$(oc get packagemanifest performance-addon-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
PAO_SUBSCRIPTION=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-performance-addon-operator-subscription
  namespace: ${PAO_NAMESPACE}
spec:
  channel: "${channel}"
  name: performance-addon-operator
  source: redhat-operators 
  sourceNamespace: openshift-marketplace
EOF
)
echo "Created \"$PAO_SUBSCRIPTION\" Subscription"

# Wait up to 15 minutes for PAO to be installed
for _ in $(seq 1 90); do
    PAO_CSV=$(oc -n "${PAO_NAMESPACE}" get subscription "${PAO_SUBSCRIPTION}" -o jsonpath='{.status.installedCSV}' || true)
    if [ -n "$PAO_CSV" ]; then
        if [[ "$(oc -n "${PAO_NAMESPACE}" get csv "${PAO_CSV}" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            FOUND_PAO=1
            break
        fi
    fi
    echo "Waiting for PAO to be installed"
    sleep 10
done
if [ -n "${FOUND_PAO}" ] ; then
    echo "PAO was installed successfully"
else
    echo "PAO was not installed after 15 minutes"
    exit 1
fi

PAO_PROFILE=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: performance.openshift.io/v1
kind: PerformanceProfile
metadata:
  name: cnf-performanceprofile
spec:
  additionalKernelArgs:
    - nmi_watchdog=0
    - audit=0
    - mce=off
    - processor.max_cstate=1
    - idle=poll
    - intel_idle.max_cstate=0
    - default_hugepagesz=1GB
    - hugepagesz=1G
    - amd_iommu=on
  cpu:
    isolated: "${CPU_ISOLATED}"
    reserved: "${CPU_RESERVED}"
  hugepages:
    defaultHugepagesSize: 1G
    pages:
      - count: $HUGEPAGES
        node: 0
        size: 1G
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  realTimeKernel:
    enabled: false
EOF
)
echo "Created \"$PAO_PROFILE\" PerformanceProfile"

check_mcp_updating 6 20 worker
check_mcp_updated 60 20 worker

echo "PerformanceProfile was successfully applied to all workers"
