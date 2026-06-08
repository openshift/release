#!/bin/bash

set -euo pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function rosa_login() {
    # ROSA_VERSION=$(rosa version)
    ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")

    if [[ ! -z "${ROSA_TOKEN}" ]]; then
      echo "Logging into ${OCM_LOGIN_ENV} with offline token using rosa cli"
      rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
      ocm login --url "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
    else
      echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
      exit 1
    fi
}

set_proxy
rosa_login

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/mgmt_kubeconfig" ]]; then
  export KUBECONFIG="${SHARED_DIR}/mgmt_kubeconfig"
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_REGION=${REGION}
export AWS_PAGER=""

# get cluster namesapce
CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
if [[ -z "${CLUSTER_NAME}" ]] ; then
  echo "Error: cluster name not found"
  exit 1
fi

read -r namespace _ _  <<< "$(oc get cluster -A | grep ${CLUSTER_NAME})"
if [[ -z "${namespace}" ]]; then
  echo "capi cluster name not found error, ${CLUSTER_NAME}"
  exit 1
fi

echo "check cluster, rosacluster status"
cluster_status=$(oc get cluster "${CLUSTER_NAME}" -n "${namespace}" -ojsonpath='{.status.phase}')
if [[ "${cluster_status}" != "Provisioned" ]]; then
  echo "Error: cluster ${CLUSTER_NAME} is not in the Provisioned status: ${cluster_status}"
  exit 1
fi

echo "check rosacontrolplane status"
rosacontrolplane_name=$(oc get cluster "${CLUSTER_NAME}" -n "${namespace}" -ojsonpath='{.spec.controlPlaneRef.name}')
is_ready=$(oc get rosacontrolplane "${rosacontrolplane_name}" -n "${namespace}" -ojsonpath='{.status.ready}')
if [[ "${is_ready}" != "true" ]]; then
  echo "Error: rosacontrolplane ${rosacontrolplane_name} is not in the ready status: ${is_ready}"
  oc get rosacontrolplane "${rosacontrolplane_name}" -n "${namespace}" -oyaml
  exit 1
fi

echo "check machinepool, rosamachinepool status"
machinepools=$(oc get MachinePools -n "${namespace}" -ojsonpath='{.items[?(@.spec.clusterName=="'"${CLUSTER_NAME}"'")].metadata.name}')
for machinepool in ${machinepools} ; do
# ignore machinepool status, it is still in the ScalingUp status when external oidc
#  mp_status=$(oc get MachinePool "${machinepool}" -n "${namespace}" -ojsonpath='{.status.phase}')
#  if [[ "${mp_status}" != "Running" ]]; then
#    echo "Error: machinepool ${machinepool} is not in the Running status: ${mp_status}"
#    exit 1
#  fi

  rosamachinepool_name=$(oc get MachinePool -n "${namespace}" "${machinepool}" -ojsonpath='{.spec.template.spec.infrastructureRef.name}')
  is_ready=$(oc get rosamachinepool "${rosamachinepool_name}" -n "${namespace}" -ojsonpath='{.status.ready}')
  if [[ "${is_ready}" != "true" ]]; then
    echo "Error: rosamachinepool ${rosamachinepool_name} is not in the ready status: ${is_ready}"
    oc get rosamachinepool "${rosamachinepool_name}" -n "${namespace}" -oyaml
    exit 1
  fi

  echo "check rosamachinepool ${machinepool} spec"
  nodepool_name=$(oc get rosamachinepool "${rosamachinepool_name}" -n "${namespace}" -ojsonpath='{.spec.nodePoolName}')
  rosa_mp_file="/tmp/rosa-mp-${nodepool_name}.json"
  rosa describe machinepool -c "${CLUSTER_NAME}" --machinepool "${nodepool_name}" -ojson > "${rosa_mp_file}"
  capi_mp_file="/tmp/capi-mp-${rosamachinepool_name}.json"
  oc get rosamachinepool "${rosamachinepool_name}" -n "${namespace}" -ojson > "${capi_mp_file}"

  capi_additional_sgs=$(jq -r '.spec.additionalSecurityGroups //""' < "${capi_mp_file}")
  rosa_additional_sgs=$(jq -r '.aws_node_pool.additional_security_group_ids //""' < "${rosa_mp_file}")
  if [[ -n "${capi_additional_sgs}" ]] && [[ -n "${rosa_additional_sgs}" ]] ; then
    echo "check rosamachinepool additional security group"
    for sg in "${capi_additional_sgs[@]}"; do
      if [[ " ${rosa_additional_sgs[*]} " != *"${sg}"* ]]; then
        echo "Error: additional security group ${sg} not found in rosa machinepool ${nodepool_name}, capi ${rosamachinepool_name}"
        exit 1
      fi
    done
  fi

  tags=$(jq -r '.spec.additionalTags //""' < "${capi_mp_file}")
  if [[ -n "${tags}" ]]; then
    echo "check rosamachinepool additional tags"
    echo "${tags}" | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read key value; do
      contain_key=$(jq -e '.aws_node_pool.tags | contains({"'"${key}"'": "'"${value}"'"})' < "${rosa_mp_file}")
      if [[ "${contain_key}" != "true" ]] ; then
        echo "Error: rosa hcp does not include tags ${key} ${value}"
        exit 1
      fi
    done
  fi

  # check auto scaling
  autosacling=$(jq -r '.spec.autoscaling //""' < "${capi_mp_file}")
  if [[ -n "${autosacling}" ]]; then
    echo "check rosamachinepool autoscaling spec"
    capi_mp_max=$(jq -r '.spec.autoscaling.maxReplicas' < "${capi_mp_file}")
    capi_mp_min=$(jq -r '.spec.autoscaling.minReplicas' < "${capi_mp_file}")
    rosa_mp_max=$(jq -r '.autoscaling.max_replica' < "${rosa_mp_file}")
    rosa_mp_min=$(jq -r '.autoscaling.min_replica' < "${rosa_mp_file}")
    if [[ "${capi_mp_max}" != "${rosa_mp_max}" ]] || [[ "${capi_mp_min}" != "${rosa_mp_min}" ]] ; then
      echo "Error: rosamachinepool ${rosamachinepool_name} autosacling not matched with nodepool ${nodepool_name}"
      exit 1
    fi
  fi
done

echo "check rosacontrolplane spec"
rosa_hcp_info_file="/tmp/${CLUSTER_NAME}.json"
capi_cp_json_file="/tmp/capi-${rosacontrolplane_name}.json"
rosa describe cluster -c ${CLUSTER_NAME} -ojson > ${rosa_hcp_info_file}
oc get rosacontrolplane ${rosacontrolplane_name} -n ${namespace} -ojson > ${capi_cp_json_file}

## check rosacontrolplane multi-az support
az_list=$(jq -r '.spec.availabilityZones[] //""' < "${capi_cp_json_file}")
for az in ${az_list} ; do
  echo "check rosacontrolplane availabilityZones"
  dft_workerpool=$(rosa list machinepool -c ${CLUSTER_NAME} | grep -E "workers.*${az}")
  if [[ -z "${dft_workerpool}" ]] ; then
    echo "Error: default machinepool not found in az ${az}"
    exit 1
  fi
done

## check rosacontrolplane domain prefix
domain_prefix=$(jq -r '.spec.domainPrefix  //""' < "${capi_cp_json_file}")
if [[ -n "${domain_prefix}" ]] ; then
  echo "check rosacontrolplane domainPrefix"
  api_url=$(jq -r '.api.url  //""' < "${rosa_hcp_info_file}")
  if [[ ! "${api_url}" =~ ${domain_prefix} ]] ; then
    echo "Error: domain prefix ${domain_prefix} not found in api url ${api_url}"
    exit 1
  fi
fi

# check endpointAccess
endpoint_access=$(jq -r '.spec.endpointAccess  //""' < "${capi_cp_json_file}")
if [[ "${endpoint_access}" == "Private" ]] ; then
  echo "check rosacontrolplane Private endpointAccess"
  api_listening=$(jq -r '.api.listening' < "${rosa_hcp_info_file}")
  if [[ "${api_listening}" != "internal" ]] ; then
    echo "Error: capi endpointAccess ${endpoint_access} does not match with rosa hcp api.listening ${api_listening}"
    exit 1
  fi
fi

# check network
capi_network_type=$(jq -r '.spec.network.networkType  //""' < "${capi_cp_json_file}")
rosa_network_type=$(jq -r '.network.type  //""' < "${rosa_hcp_info_file}")
echo "check rosacontrolplane networkType"
if [[ "${capi_network_type}" != "${rosa_network_type}" ]] ; then
    echo "Error: capi network type ${capi_network_type} does not match with rosa hcp network type ${rosa_network_type}"
    exit 1
fi

capi_machine_cidr=$(jq -r '.spec.network.machineCIDR  //""' < "${capi_cp_json_file}")
rosa_machine_cidr=$(jq -r '.network.machine_cidr  //""' < "${rosa_hcp_info_file}")
echo "check rosacontrolplane machineCIDR"
if [[ "${capi_machine_cidr}" != "${rosa_machine_cidr}" ]] ; then
    echo "Error: capi network machineCIDR ${capi_machine_cidr} does not match with rosa hcp network machine.cidr ${rosa_machine_cidr}"
    exit 1
fi

# check additional tags
tags=$(jq -r '.spec.additionalTags  //""' < "${capi_cp_json_file}")
if [[ -n "${tags}" ]]; then
  echo "check rosacontrolplane additionalTags"
  hc_dft_sg=""
  if [[ -f "${SHARED_DIR}/capi_hcp_default_security_group" ]] ; then
    hc_dft_sg=$(cat "${SHARED_DIR}/capi_hcp_default_security_group")
  else
    cluster_id=$(cat "${SHARED_DIR}/cluster-id")
    hc_vpc_id=$(cat "${SHARED_DIR}/vpc_id")
    hc_dft_sg=$(aws ec2 describe-security-groups --region ${REGION} --filters "Name=vpc-id,Values=${hc_vpc_id}" "Name=group-name,Values=${cluster_id}-default-sg" --query 'SecurityGroups[].GroupId' --output text)
  fi

  if [[ -z "${hc_dft_sg}" ]] ; then
    echo "default security group not found error"
    exit 1
  fi

  echo "${tags}" | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read key value; do
    contain_key=$(jq -e '.aws.tags | contains({"'"${key}"'": "'"${value}"'"})' < "${rosa_hcp_info_file}")
    if [[ "${contain_key}" != "true" ]] ; then
      echo "Error: rosa hcp does not include tags ${key} ${value}"
      exit 1
    fi

    res=$(aws ec2 describe-security-groups --group-ids "${hc_dft_sg}" | jq -r '.SecurityGroups[0].Tags[] | select(.Key == "'"${key}"'" and .Value == "'"${value}"'")')
    if [[ -z "${res}" ]]; then
      echo "Error: additional tag ${key}:${value} not found in default hcp security group ${hc_dft_sg}"
      exit 1
    fi
  done
fi

# check etcd kms key
etcd_kms_arn=$(jq -r '.spec.etcdEncryptionKMSARN  //""' < "${capi_cp_json_file}")
if [[ -n "${etcd_kms_arn}" ]]; then
  echo "check rosacontrolplane etcdEncryptionKMSARN"
  rosa_etcd_encryption=$(jq -r '.etcd_encryption' < "${rosa_hcp_info_file}")
  if [[ "${rosa_etcd_encryption}" != "true" ]] ; then
    echo "Error: etcd_encryption is not true ${rosa_etcd_encryption}"
    exit 1
  fi

  rosa_etcd_kms_arn=$(jq -r '.aws.etcd_encryption.kms_key_arn  //""' < "${rosa_hcp_info_file}")
  if [[ "${rosa_etcd_kms_arn}" != "${etcd_kms_arn}" ]] ; then
    echo "Error: etcd kms role is not matched, etcdEncryptionKMSArn: ${etcd_kms_arn}, rosa_etcd_kms_arn: ${rosa_etcd_kms_arn}"
    exit 1
  fi
fi

# check audit log
audit_log_role=$(jq -r '.spec.auditLogRoleARN  //""' < "${capi_cp_json_file}")
if [[ -n "${audit_log_role}" ]]; then
  echo "check rosacontrolplane auditLogRoleARN"
  rosa_audit_log_role=$(jq -r '.aws.audit_log.role_arn' < "${rosa_hcp_info_file}")
  if [[ -z "${rosa_audit_log_role}" ]] || [[ "${audit_log_role}" != "${rosa_audit_log_role}" ]]; then
    echo "Error: audit log role arn not matched, rosacontrolplane.spec.auditLogRoleARN %{audit_log_role}, ${rosa_audit_log_role}"
    exit 1
  fi
fi

echo "health check done"



