#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function check_workers_updated() {
    # Wait up to 30 minutes for the performance profile to be applied.
    # This includes time for NTO to create the MachineConfig and for
    # the MCO to roll it out to worker nodes (which requires a reboot).
    INTERVAL=30
    CNT=60

    while [ $((CNT)) -gt 0 ]; do
        READY=false
        while read -r i
        do
            name=$(echo "${i}" | awk '{print $1}')
            current_config=$(echo "${i}" | awk '{print $2}')
            updated=$(echo "${i}" | awk '{print $3}')
            updating=$(echo "${i}" | awk '{print $4}')
            degraded=$(echo "${i}" | awk '{print $5}')
            degraded_machine_cnt=$(echo "${i}" | awk '{print $9}')

            if [[ "${old_config}" != "${current_config}" && "${updated}" == "True" && "${updating}" == "False" && "${degraded}" == "False" && $((degraded_machine_cnt)) -eq 0 ]]; then
                READY=true
            else
                echo "Waiting for mcp ${name} to rollout (updated=${updated} updating=${updating} degraded=${degraded})"
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
  globallyDisableIrqLoadBalancing: true
EOL

PAO_PROFILE=$(oc create -f /tmp/performance_profile.yaml -o jsonpath='{.metadata.name}')
echo "Created \"$PAO_PROFILE\" PerformanceProfile"

check_workers_updated

echo "PerformanceProfile was successfully applied to the worker config"
