#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION="${LEASED_RESOURCE}"
# INFRA_ID=$(jq -r '.infraID' ${SHARED_DIR}/metadata.json)
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "====== MachineSet"
oc get machineset -n openshift-machine-api -owide
echo "====== Machines"
oc get machines -n openshift-machine-api -owide
echo "====== Nodes"
oc get node -owide

MACHINESETS=$(oc get machineset -n openshift-machine-api --no-headers | grep edge | awk '{print$1}')
MACHINES=$(oc get machines -n openshift-machine-api --no-headers | grep edge | awk '{print$1}')
NODES=$(oc get node --no-headers | grep edge | awk '{print$1}')
# machineset=$MACHINESETS

echo "EDGE_ZONE_TYPE: ${EDGE_ZONE_TYPE}"
echo "LOCALZONE_WORKER_SCHEDULABLE: ${LOCALZONE_WORKER_SCHEDULABLE}"
echo "LOCALZONE_WORKER_ASSIGN_PUBLIC_IP: ${LOCALZONE_WORKER_ASSIGN_PUBLIC_IP}"

ret=0

for machineset in $MACHINESETS;
do
  schedulable_effect=$(oc get machineset -n openshift-machine-api $machineset -o json | jq -r '.spec.template.spec.taints[] | select(.key=="node-role.kubernetes.io/edge") | .effect')
  public_ip=$(oc get machineset -n openshift-machine-api $machineset -o json | jq -r '.spec.template.spec.providerSpec.value.publicIp')
  echo "MACHINESET: ${machineset}: schedulable_effect:[${schedulable_effect}], public_ip:[${public_ip}]"

  if [[ ${LOCALZONE_WORKER_SCHEDULABLE} == "yes" ]] && ([[ ${schedulable_effect} == "" ]] || [[ ${schedulable_effect} == "null" ]]); then
    echo "PASS: machineset schedulable: ${machineset}"
  elif [[ ${LOCALZONE_WORKER_SCHEDULABLE} == "no" ]] && [[ ${schedulable_effect} == "NoSchedule" ]]; then
    echo "PASS: machineset schedulable: ${machineset}"
  else
    echo "FAIL: machineset schedulable: ${machineset}"
    ret=$((ret+1))
  fi

  # Checking public ip
  if [[ ${LOCALZONE_WORKER_ASSIGN_PUBLIC_IP} == "yes" ]] && [[ "${public_ip}" == "true" ]]; then
    echo "PASS: machineset public ip: ${machineset}"
  elif [[ ${LOCALZONE_WORKER_ASSIGN_PUBLIC_IP} == "no" ]] && ([[ "${public_ip}" == "" ]] || [[ "${public_ip}" == "null" ]]); then
    echo "PASS: machineset public ip: ${machineset}"
  else
    echo "FAIL: machineset public ip: ${machineset}"
    ret=$((ret+1))
  fi

done

for machine in $MACHINES;
do
  instance_id=$(oc get machines -n openshift-machine-api ${machine} -o json | jq -r '.status.providerStatus.instanceId')
  external_dns=$(oc get machine -n openshift-machine-api ${machine} -o json | jq -r '.status.addresses[] | select(.type=="ExternalDNS") | .address')
  internal_dns=$(oc get machine -n openshift-machine-api ${machine} -o json | jq -r '.status.addresses[] | select(.type=="InternalDNS") | .address')

  machine_info="instance_id:[${instance_id}], external_dns:[${external_dns}], internal_dns:[${internal_dns}]"

  if [[ ${EDGE_ZONE_TYPE} == "wavelength-zone" ]]; then
    carrier_ip=$(aws ec2 describe-instances --region ${REGION} --instance-ids $instance_id | jq -r '.Reservations[].Instances[].NetworkInterfaces[].Association.CarrierIp')
    machine_info="${machine_info}, carrier_ip:[${carrier_ip}]"
  fi

  echo "MACHINE: ${machine}: ${machine_info}"
  
  # Checking
  if [[ ${EDGE_ZONE_TYPE} == "wavelength-zone" ]]; then
    if [[ ${LOCALZONE_WORKER_ASSIGN_PUBLIC_IP} == "yes" ]] && [[ ${external_dns} == ec2* ]] && [[ "${carrier_ip}" != "" ]] && [[ "${carrier_ip}" != "null" ]]; then
      echo "PASS: machine public ip assignment: ${machine}"
    elif [[ ${LOCALZONE_WORKER_ASSIGN_PUBLIC_IP} == "no" ]] && ([[ "${external_dns}" == "" ]] || [[ "${external_dns}" == "null" ]]) && ([[ "${carrier_ip}" == "" ]] || [[ "${carrier_ip}" == "null" ]]); then
      echo "PASS: machine public ip assignment: ${machine}"
    else
      echo "FAIL: machine public ip assignment: ${machine}"
      ret=$((ret+1))
    fi
  else
    # local-zone
    if [[ ${LOCALZONE_WORKER_ASSIGN_PUBLIC_IP} == "yes" ]] && [[ ${external_dns} == ec2* ]]; then
      echo "PASS: machine public ip assignment: ${machine}"
    elif [[ ${LOCALZONE_WORKER_ASSIGN_PUBLIC_IP} == "no" ]] && ([[ "${external_dns}" == "" ]] || [[ "${external_dns}" == "null" ]]); then
      echo "PASS: machine public ip assignment: ${machine}"
    else
      echo "FAIL: machine public ip assignment: ${machine}"
      ret=$((ret+1))
    fi
  fi
done

for node in $NODES;
do
  schedulable_effect=$(oc get node $node -o json | jq -r '.spec.taints[] | select(.key=="node-role.kubernetes.io/edge") | .effect')
  echo "NODE: ${node}: schedulable_effect:[${schedulable_effect}]"


  if [[ ${LOCALZONE_WORKER_SCHEDULABLE} == "yes" ]] && ([[ ${schedulable_effect} == "" ]] || [[ ${schedulable_effect} == "null" ]]); then
    echo "PASS: node schedulable: ${node}"
  elif [[ ${LOCALZONE_WORKER_SCHEDULABLE} == "no" ]] && [[ ${schedulable_effect} == "NoSchedule" ]]; then
    echo "PASS: node schedulable: ${node}"
  else
    echo "FAIL: node schedulable: ${node}"
    ret=$((ret+1))
  fi

  # echo "Node debugging"
  # oc debug -n default node/${node} -- chroot /host ip address show ovn-k8s-mp0
done

# MTU
CLUSTER_MTU=$(oc get network.config cluster -o=jsonpath='{.status.clusterNetworkMTU}')
NETWORK_TYPE=$(oc get network.config cluster -o=jsonpath='{.status.networkType}')

echo "Cluster MTU: ${CLUSTER_MTU}"
echo "Cluster Network Type: ${NETWORK_TYPE}"
if [[ $NETWORK_TYPE == "OpenShiftSDN" ]]; then
  echo "Expected MTU: ${EXPECTED_MTU_SDN}"
  if [[ "${CLUSTER_MTU}" == "${EXPECTED_MTU_SDN}" ]]; then
    echo "PASS: Cluster MTU"
  else
    echo "FAIL: Cluster MTU"
    ret=$((ret+1))
  fi
elif [[ $NETWORK_TYPE == "OVNKubernetes" ]]; then
  echo "Expected MTU: ${EXPECTED_MTU_OVN}"
  if [[ "${CLUSTER_MTU}" == "${EXPECTED_MTU_OVN}" ]]; then
    echo "PASS: Cluster MTU"
  else
    echo "FAIL: Cluster MTU"
    ret=$((ret+1))
  fi
fi

exit $ret
