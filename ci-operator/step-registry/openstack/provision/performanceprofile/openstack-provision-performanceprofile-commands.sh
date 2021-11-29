#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function check_workers_updating() {
    INTERVAL=6
    CNT=20

    while [ $((CNT)) -gt 0 ]; do
        UPDATING=false
        while read -r i
        do
            name=$(echo "${i}" | awk '{print $1}')
            updating=$(echo "${i}" | awk '{print $4}')
            if [[ "${updating}" == "True" ]]; then
                UPDATING=true
            else
                echo "Waiting for mcp ${name} to start rolling out"
                UPDATING=false
            fi
        done <<< "$(oc get mcp worker --no-headers)"

        if [[ "${UPDATING}" == "true" ]]; then
            echo "Workers are rolling out"
            return 0
        else
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "Workers did not successfully start rolling out"
            oc get mcp "${name}"
            return 1
        fi
    done
}

function check_workers_updated() {
    INTERVAL=60
    CNT=20

    while [ $((CNT)) -gt 0 ]; do
        READY=false
        while read -r i
        do
            name=$(echo "${i}" | awk '{print $1}')
            updated=$(echo "${i}" | awk '{print $3}')
            updating=$(echo "${i}" | awk '{print $4}')
            degraded=$(echo "${i}" | awk '{print $5}')
            degraded_machine_cnt=$(echo "${i}" | awk '{print $9}')

            if [[ "${updated}" == "True" && "${updating}" == "False" && "${degraded}" == "False" && $((degraded_machine_cnt)) -eq 0 ]]; then
                READY=true
            else
                echo "Waiting for mcp ${name} to rollout"
                READY=false
            fi
        done <<< "$(oc get mcp worker --no-headers)"

        if [[ "${READY}" == "true" ]]; then
            echo "Workers have successfully rolled out"
            return 0
        else
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "Workers did not successfully roll out"
            oc get mcp "${name}"
            return 1
        fi
    done
}

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

check_workers_updating
check_workers_updated

echo "PerformanceProfile was successfully applied to all workers"
