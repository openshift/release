#!/bin/bash
#set -x
#set -o nounset
#set -o errexit
#set -o pipefail

function queue() {
  local TARGET="${1}"
  shift
  local LIVE
  LIVE="$(jobs | wc -l)"
  while [[ "${LIVE}" -ge 45 ]]; do
    sleep 1
    LIVE="$(jobs | wc -l)"
  done
  echo "${@}"
  if [[ -n "${FILTER:-}" ]]; then
    "${@}" | "${FILTER}" >"${TARGET}" &
  else
    "${@}" >"${TARGET}" &
  fi
}

export PATH=$PATH:/tmp/shared

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering extra artifacts."
	exit 0
fi

echo "Gathering network ovn artifacts ..."

mkdir -p ${ARTIFACT_DIR}/network-ovn

echo "Running gather network..."

oc --insecure-skip-tls-verify --request-timeout=5s get nodes -o jsonpath \
	--template '{range .items[*]}{.metadata.name}{"\n"}{end}' > /tmp/nodes
oc --insecure-skip-tls-verify --request-timeout=5s -n openshift-ovn-kubernetes get pods --no-headers \
	-o custom-columns=':metadata.name' -l app=ovnkube-master > /tmp/master-pods

while IFS= read -r i; do
  OVS_NODE_POD=$(oc --insecure-skip-tls-verify --request-timeout=20s -n openshift-ovn-kubernetes \
	  get pods --no-headers -o custom-columns=":metadata.name" --field-selector spec.nodeName=${i} -l app=ovs-node)

# OVNKUBE_NODE=$(oc --insecure-skip-tls-verify --request-timeout=20s -n openshift-ovn-kubernetes \
#	  get pods --no-headers -o custom-columns=":metadata.name" --field-selector spec.nodeName=${i} -l app=ovnkube-node)

  OVNKUBE_MASTER=$(oc --insecure-skip-tls-verify --request-timeout=20s -n openshift-ovn-kubernetes \
	  get pods --no-headers -o custom-columns=':metadata.name' --field-selector spec.nodeName=${i} -l app=ovnkube-master)

  queue ${ARTIFACT_DIR}/network-ovn/${i}--${OVS_NODE_POD}--ovs_ofctl_dump_ports_br_int  \
	  oc --insecure-skip-tls-verify -n openshift-ovn-kubernetes exec --request-timeout=30s ${OVS_NODE_POD} -- bash -c \
	            "ovs-ofctl dump-ports-desc br-int"

  queue ${ARTIFACT_DIR}/network-ovn/${i}--${OVS_NODE_POD}--ovs_ofctl_dump_flows_br_int   \
      	  oc --insecure-skip-tls-verify -n openshift-ovn-kubernetes exec --request-timeout=30s ${OVS_NODE_POD} -- bash -c \
        "ovs-ofctl dump-flows br-int"

  queue ${ARTIFACT_DIR}/network-ovn/${i}--${OVS_NODE_POD}--ovs_ofctl_dump_ports_br_local  \
	  oc --insecure-skip-tls-verify -n openshift-ovn-kubernetes exec --request-timeout=30s ${OVS_NODE_POD} -- bash -c \
            "ovs-ofctl dump-ports-desc br-local"

  queue ${ARTIFACT_DIR}/network-ovn/${i}--${OVS_NODE_POD}--ovs_ofctl_dump_flows_br_local   \
      	  oc --insecure-skip-tls-verify -n openshift-ovn-kubernetes exec --request-timeout=30s ${OVS_NODE_POD} -- bash -c \
        "ovs-ofctl dump-flows br-local"

  queue ${ARTIFACT_DIR}/network-ovn/${i}--${OVS_NODE_POD}--ovs_dump  \
	  oc --insecure-skip-tls-verify -n openshift-ovn-kubernetes exec --request-timeout=30s ${OVS_NODE_POD} -- bash -c \
            "ovs-vsctl show"

  if [[ ${OVNKUBE_MASTER} != "" ]] ; then
    queue ${ARTIFACT_DIR}/network-ovn/${i}--${OVNKUBE_MASTER}--ovn_nbctl_show  \
      oc --insecure-skip-tls-verify -n openshift-ovn-kubernetes exec --request-timeout=30s -c ovnkube-master ${OVNKUBE_MASTER} -- bash -c \
        "ovn-nbctl show"

    queue ${ARTIFACT_DIR}/network-ovn/${i}--${OVNKUBE_MASTER}--ovn_sbctl_show  \
      oc --insecure-skip-tls-verify -n openshift-ovn-kubernetes exec --request-timeout=30s -c ovnkube-master ${OVNKUBE_MASTER} -- bash -c \
        "ovn-sbctl show"

    queue ${ARTIFACT_DIR}/network-ovn/${i}--${OVNKUBE_MASTER}--ovn_nbctl_list_lsp  \
      oc --insecure-skip-tls-verify -n openshift-ovn-kubernetes exec --request-timeout=30s -c ovnkube-master ${OVNKUBE_MASTER} -- bash -c \
        "ovn-nbctl list Logical_Switch_Port"

    queue ${ARTIFACT_DIR}/network-ovn/${i}--${OVNKUBE_MASTER}--ovn_nbctl_list_lb  \
      oc --insecure-skip-tls-verify -n openshift-ovn-kubernetes exec --request-timeout=30s -c ovnkube-master ${OVNKUBE_MASTER} -- bash -c \
        "ovn-nbctl list Load_Balancer"

    queue ${ARTIFACT_DIR}/network-ovn/${i}--${OVNKUBE_MASTER}--ovn_nbctl_list_pg  \
      oc --insecure-skip-tls-verify -n openshift-ovn-kubernetes exec --request-timeout=30s -c ovnkube-master ${OVNKUBE_MASTER} -- bash -c \
        "ovn-nbctl list Port_Group"

    queue ${ARTIFACT_DIR}/network-ovn/${i}--${OVNKUBE_MASTER}--ovn_nbctl_list_acl  \
      oc --insecure-skip-tls-verify -n openshift-ovn-kubernetes exec --request-timeout=30s -c ovnkube-master ${OVNKUBE_MASTER} -- bash -c \
        "ovn-nbctl list ACL"
  fi

done < /tmp/nodes
