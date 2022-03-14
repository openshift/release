#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function check_workers_updated() {
    # Wait up to 2 minutes for PAO to update the worker config
    INTERVAL=5
    CNT=24

    while [ $((CNT)) -gt 0 ]; do
        READY=false
        while read -r i
        do
            name=$(echo "${i}" | awk '{print $1}')
            current_config=$(echo "${i}" | awk '{print $2}')
            degraded=$(echo "${i}" | awk '{print $5}')
            degraded_machine_cnt=$(echo "${i}" | awk '{print $9}')

            if [[ "${old_config}" != "${current_config}" && "${degraded}" == "False" && $((degraded_machine_cnt)) -eq 0 ]]; then
                READY=true
            else
                echo "Waiting for mcp ${name} to rollout"
                READY=false
            fi
        done <<< "$(oc get mcp worker --no-headers)"

        if [[ "${READY}" == "true" ]]; then
            echo "Worker config has successfully rolled out"
            return 0
        else
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "Worker config did not successfully roll out"
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

HUGEPAGES="${HUGEPAGES:-4}"
CPU_ISOLATED="${CPU_ISOLATED:-2-7}"
CPU_RESERVED="${CPU_RESERVED:-0-1}"
old_config=$(oc get mcp worker --no-headers | awk '{print $2}')

cat >/tmp/performance_profile.yaml <<EOL
apiVersion: performance.openshift.io/v2
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
    - amd_iommu=on
  cpu:
    isolated: "${CPU_ISOLATED}"
    reserved: "${CPU_RESERVED}"
  hugepages:
    defaultHugepagesSize: "1G"
    pages:
      - count: ${HUGEPAGES}
        node: 0
        size: 1G
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  realTimeKernel:
    enabled: false
EOL

oc_version=$(oc version | cut -d ' ' -f 3 | cut -d '.' -f1,2 | sed -n '2p')
case "${oc_version}" in
    # Remove 4.11 once it's GA
    4.11) dev_version=master ;;
    *) ;;
esac

if [ -n "${dev_version:-}" ]; then
    git clone --branch ${dev_version} https://github.com/openshift-kni/performance-addon-operators /tmp/performance-addon-operators
    pushd /tmp/performance-addon-operators
    if [[ ! -f cluster-setup/manual-cluster/performance/performance_profile.yaml ]]; then
        echo "performance_profile.yaml was not found in the PAO repository"
        exit 1
    fi
    cp /tmp/performance_profile.yaml cluster-setup/manual-cluster/performance/
    export CLUSTER=manual
    make cluster-deploy
    popd
else
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

    if [ -n "${FOUND_PAO:-}" ] ; then
        # Wait 30 seconds for PAO to starting the different components
        sleep 30
        echo "PAO was installed successfully"
    else
        echo "PAO was not installed after 15 minutes"
        exit 1
    fi

    PAO_PROFILE=$(oc create -f /tmp/performance_profile.yaml -o jsonpath='{.metadata.name}')
    echo "Created \"$PAO_PROFILE\" PerformanceProfile"
fi

check_workers_updated

echo "PerformanceProfile was successfully applied to the worker config"
