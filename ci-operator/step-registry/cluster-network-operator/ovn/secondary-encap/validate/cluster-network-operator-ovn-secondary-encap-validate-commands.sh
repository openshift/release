#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ cluster-network-operator ovn secondary encap validate ************"

namespace="openshift-ovn-kubernetes"
mapping_file="${SHARED_DIR}/cno-secondary-encap-mapping.tsv"
artifacts_dir="${ARTIFACT_DIR:-${SHARED_DIR}}"

if [[ ! -s "${mapping_file}" ]]; then
  echo "missing expected encap mapping file: ${mapping_file}" >&2
  exit 1
fi

# get_ovnkube_container returns the container name that provides the OVN
# tooling inside an ovnkube-node pod.
get_ovnkube_container() {
  local pod_name="$1"
  local containers

  containers=$(oc get pod -n "${namespace}" "${pod_name}" -o jsonpath='{.spec.containers[*].name}')
  for candidate in ovnkube-controller ovnkube-node; do
    if [[ " ${containers} " == *" ${candidate} "* ]]; then
      echo "${candidate}"
      return 0
    fi
  done

  echo "unable to find a supported OVN container in pod ${pod_name}" >&2
  return 1
}

oc wait pod -n "${namespace}" -l app=ovnkube-node --for=condition=Ready --timeout=10m

validation_failed=0
while IFS=$'\t' read -r node_name expected_ip expected_iface _pod_name; do
  pod_name=$(oc get pods -n "${namespace}" -l app=ovnkube-node --field-selector "spec.nodeName=${node_name}" -o jsonpath='{.items[0].metadata.name}')
  if [[ -z "${pod_name}" ]]; then
    echo "unable to find ovnkube-node pod for node ${node_name}" >&2
    validation_failed=1
    continue
  fi

  container_name=$(get_ovnkube_container "${pod_name}")
  show_file="${artifacts_dir}/${node_name}-ovs-vsctl-show.txt"
  extids_file="${artifacts_dir}/${node_name}-ovs-vsctl-external-ids.txt"

  echo "Validating node ${node_name}: expected encap IP ${expected_ip} on ${expected_iface}"

  oc exec -n "${namespace}" "${pod_name}" -c "${container_name}" -- ovs-vsctl show | tee "${show_file}"
  oc exec -n "${namespace}" "${pod_name}" -c "${container_name}" -- ovs-vsctl get Open_vSwitch . external_ids | tee "${extids_file}"

  actual_ip=$(oc exec -n "${namespace}" "${pod_name}" -c "${container_name}" -- ovs-vsctl get Open_vSwitch . external_ids:ovn-encap-ip | tr -d '"')
  if [[ "${actual_ip}" != "${expected_ip}" ]]; then
    echo "encap IP mismatch on ${node_name}: expected ${expected_ip}, got ${actual_ip}" >&2
    validation_failed=1
    continue
  fi

  if ! grep -Fq "${expected_ip}" "${show_file}"; then
    echo "ovs-vsctl show output for ${node_name} did not contain ${expected_ip}; using external_ids:ovn-encap-ip as the source of truth"
  fi
done < "${mapping_file}"

exit "${validation_failed}"
