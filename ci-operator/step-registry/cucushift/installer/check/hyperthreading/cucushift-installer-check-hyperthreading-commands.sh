#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
    echo "Unable to find kubeconfig under ${SHARED_DIR}!"
    exit 1
fi

CONFIG=${SHARED_DIR}/install-config.yaml
if [ ! -f "${CONFIG}" ] ; then
    echo "Unable to find install config, exit now."
    exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

function check_machine_config_hyperthreading()
{
    local role=$1
    if oc get machineconfig --no-headers | grep -q 99-${role}-disable-hyperthreading; then
        echo "Disabled: ${role}: Machine Config"
    else
        echo "Enabled: ${role}: Machine Config"
    fi
}

function check_node_hyperthreading()
{
    local node_name=$1
    local log cpuinfo_log
    log=${ARTIFACT_DIR}/${node_name}.log
    cpuinfo_log=${ARTIFACT_DIR}/cpuinfo_${node_name}.log

    echo "Checking Hyperthreading for $node_name"

    oc debug node/${node_name} -- chroot /host /bin/bash -c "cat /proc/cpuinfo" | tee $cpuinfo_log

    siblings_num=$(cat $cpuinfo_log | grep 'siblings.*:' | head -1 | awk -F':' '{print $2}' | tr -d '[:blank:]' | tr -d '\r')
    cpu_cores_num=$(cat $cpuinfo_log | grep 'cpu cores.*:' | head -1 | awk -F':' '{print $2}' | tr -d '[:blank:]' | tr -d '\r')

    if [ "$siblings_num" == "" ] || [ "$cpu_cores_num" == "" ]; then
        echo -e "\nERROR: $node_name: Fail to detect!" | tee -a $log
        return 1
    fi

    local n
    n=$((siblings_num/cpu_cores_num))
    if [ $n -ge 2 ]; then
        echo -e "\nEnabled: $node_name" | tee -a $log
        return 0
    elif [ $n -eq 1 ]; then
        echo -e "\nDisabled: $node_name" | tee -a $log
        return 0
    else
        echo -e "\nERROR: $node_name: Something wrong!" | tee -a $log
        return 1
    fi
}

ret=0

EXCEPT_COMPUTE_NODE_HYPERTHREADING=$(yq-go r "${CONFIG}" 'compute[0].hyperthreading')
if [ "${EXCEPT_COMPUTE_NODE_HYPERTHREADING}" == "" ]; then
    echo "No hyperthreading was found for compute nodes  in install-config, the default Enabled is excepted."
    EXCEPT_COMPUTE_NODE_HYPERTHREADING="Enabled"
fi

EXCEPT_CONTROL_PLANE_NODE_HYPERTHREADING=$(yq-go r "${CONFIG}" 'controlPlane.hyperthreading')
if [ "${EXCEPT_CONTROL_PLANE_NODE_HYPERTHREADING}" == "" ]; then
    echo "No hyperthreading was found for control plane nodes in install-config, the default Enabled is excepted."
    EXCEPT_CONTROL_PLANE_NODE_HYPERTHREADING="Enabled"
fi

tmp=$(mktemp)

for role in worker master;
do
    if [ "${role}" == "worker" ]; then
        except_result=$EXCEPT_COMPUTE_NODE_HYPERTHREADING
    elif [ "${role}" == "master" ]; then
        except_result=$EXCEPT_CONTROL_PLANE_NODE_HYPERTHREADING
    else
        echo "${role} is not supported"
        exit 1
    fi

    echo "Except: ${role}: ${except_result}"

    if check_machine_config_hyperthreading ${role} | grep -qE "^${except_result}.*"; then
        echo "** PASS: ${role}: Machine Config, hyperthreading ${except_result}"
    else
        echo "** ERROR: ${role}: Machine Config, expect hyperthreading ${except_result}"
        ret=$((ret+1))
    fi

    oc get node --no-headers | grep ${role} | awk '{print $1}' > ${tmp}
    while read -r node; do
        if check_node_hyperthreading ${node} | grep -qE "^${except_result}.*"; then
            echo "** PASS: ${role}: ${node}: hyperthreading ${except_result}"
        else
            echo "** ERROR: ${role}: ${node}: expect hyperthreading ${except_result}"
            ret=$((ret+1))
        fi
    done < ${tmp}
done

exit ${ret}