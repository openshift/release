#!/usr/bin/env bash

set -x
set +eu

BASE_DIR=${HOME:-"/alabama"}
MUST_GATHER_TIMEOUT=${MUST_GATHER_TIMEOUT:-"5m"}
NS_OPERATORS=${NS_OPERATORS:-"openstack"}
NS_SERVICES=${NS_SERVICES:-"openstack"}

# Creates directory if does not exists
#  Parameters:
#  $1: directory to be created
function create_out_dir {
  local OUT_DIR=${1}
  if [ ! -d "./${OUT_DIR}" ]; then
    mkdir -p ${OUT_DIR}
  fi
}

# Generates a debug command toz get pods logs and description. To be used with "xargs -I {}".
#  Parameters:
#  $1: directory to store output logs (optional)
function gen_pods_debug_cmd {
  local cmd
  if [ -z "${1}" ]; then
    cmd=("echo 'Logs for pod: {}'; oc describe pod {} > {}-describe.log; oc logs --prefix=true --all-containers=true {} >> {}-containers.log")
  else
    create_out_dir ${1}
    cmd=("echo 'Logs for pod: {}'; oc describe pod {} > ${1}/{}-describe.log; oc logs --prefix=true --all-containers=true {} >> ${1}/{}-containers.log")
  fi
  echo "${cmd[@]}"
}

# Generates a debug command to get yaml output for a resource. To be used with "xargs -I {}".
#  Parameters:
#  $1: directory to store output logs (optional)
function gen_resource_yaml_debug_cmd {
  local cmd
  if [ -z "${1}" ]; then
    cmd=("echo 'Getting info for {} resource'; oc get {} -o yaml > {}.yaml")
  else
    create_out_dir ${1}
    cmd=("echo 'Getting info for {} resource'; oc get {} -o yaml > ${1}/{}.yaml")
  fi
  echo "${cmd[@]}"
}

# Get all yaml outputs from resource in "oc get all" result.
#  Parameters:
#  $1: namespace
#  $2: string to be used in egrep to filter results (optional)
function get_all_from_ns {
  local get_all
  local cmd
  local dir
  if [ -z "${2}" ]; then
    get_all=$(oc get all -o name -n "${1}")
  else
    get_all=$(oc get all -o name -n "${1}" | egrep -iv "${2}")
  fi

  cmd=$(gen_resource_yaml_debug_cmd)
  for i in ${get_all}; do
    dir=$(echo $i | cut -d "/" -f1)
    create_out_dir "${dir}"
    echo ${i} | xargs -n1 -I {} sh -c "${cmd[@]}"
  done
}

# We don't want to use OpenShift-CI build cluster namespace
unset NAMESPACE
oc project "${NS_OPERATORS}"

pushd "${BASE_DIR}" || exit
mkdir logs
pushd logs || exit

oc get all > get_all.log

# api-resources - OpenStack
CMD=$(gen_resource_yaml_debug_cmd "api-resources")
oc api-resources | grep 'openstack' | awk '{print $1}' | xargs -n1 -I {} sh -c "${CMD[@]}"
# RabbitMQCluster
oc get -o yaml RabbitMQCluster > RabbitMQCluster.yaml

### Pods
# Pods - controller manager
CMD=$(gen_pods_debug_cmd "controller-manager")
oc get pods -n "${NS_OPERATORS}" --show-labels | grep -i '.*control\-plane\=.*controller\-manager.*' | awk '{print $1}' | \
xargs -n1 -I {} sh -c "${CMD[@]}"

# Pods - all others
CMD=$(gen_pods_debug_cmd "pods")
oc get pods -n "${NS_SERVICES}" --no-headers | egrep -iv controller | awk '{print $1}' | xargs -n1 -I {} sh -c "${CMD[@]}"

# Pods in error
CMD=$(gen_pods_debug_cmd "errors")
# Capture logs from service containers if container is not in Running or Completed state
oc get pods -n "${NS_SERVICES}" --no-headers | egrep -iv controller | egrep -iv 'Running|Completed' | awk '{print $1}' | \
xargs -n1 -I {} sh -c "${CMD[@]}"

### Get all from namespaces
# excluding pods from ALL
get_all_from_ns ${NS_OPERATORS} "pod"
if [[ "$NS_SERVICES" != "$NS_OPERATORS" ]]; then
  get_all_from_ns ${NS_SERVICES} "pod"
fi

# For network isolation
oc get network-attachment-definition -n "${NS_SERVICES}" -o yaml > net-attachment-definition.yaml
oc get nncp -n "${NS_SERVICES}" -o yaml > nncp.yaml
oc get ipaddresspool -n metallb-system -o yaml > ipaddresspool.yaml
oc get l2advertisement -n metallb-system -o yaml > l2advertisement.yaml

# must-gather
# TODO: use openstack-k8s-operator must-gather image when available
mkdir -p ${ARTIFACT_DIR}/must-gather/
oc --insecure-skip-tls-verify adm must-gather --timeout=$MUST_GATHER_TIMEOUT \
--dest-dir ${ARTIFACT_DIR}/must-gather > ${ARTIFACT_DIR}/must-gather/must-gather.log

# logs dir
popd || exit
cp -r logs/* "${ARTIFACT_DIR}"

popd || exit
