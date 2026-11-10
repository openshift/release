#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -z "${CONTROL_ARCH}" ] || [ -z "${COMPUTE_ARCH}" ]; then
  echo "[WARN] Skipping this test as either CONTROL_ARCH or COMPUTE_ARCH are not set."
  exit 0
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

function debug() {
  echo "[DEBUG] Current machinesets, machines and nodes are:"
  set +e
  for resource in machinesets.machine.openshift.io machines.machine.openshift.io nodes; do
    oc -n openshift-machine-api get "${resource}" -owide | tee "${ARTIFACT_DIR}/${resource}.txt"
    oc -n openshift-machine-api get "${resource}" -oyaml | tee "${ARTIFACT_DIR}/${resource}.yaml"
    oc -n openshift-machine-api describe "${resource}"   | tee "${ARTIFACT_DIR}/${resource}-describe.txt"
  done
  set -e
}

# normalize_arch returns the normalized architecture name as llvm/golang uses it.
function normalize_arch() {
  echo "${1}" | tr '[:upper:]' '[:lower:]' | sed -e 's/aarch64/arm64/;s/x86_64/amd64/'
}

# get_nodes_arch_by_label returns the architecture of the nodes with the given label.
# If more architectures are detected, it returns space separated and sorted list of unique architectures.
function get_nodes_arch_by_label() {
  oc get nodes -l "${1}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.kubernetes\.io/arch}{"\n"}{end}' | \
    cut -f2 -d' ' | sort -u | tr '\n' ' ' | sed -e 's/ $//'
}

# verify_arch_by_role_label checks if the nodes with the given label have the expected architecture
# It takes 3 arguments:
# - role: the role of the nodes to check. It's used for informational purposes only.
# - label: the label to filter the nodes.
# - expected: the expected architecture of the nodes.
# The function depends on get_nodes_arch_by_label. Since it returns a sorted list of unique architectures,
# this function can take a space separated list of architectures as the expected argument, for example,
# to verify clusters with mixed architecture workers.
function verify_arch_by_role_label() {
  role="${1}"
  label="${2}"
  echo "[INFO] Checking the ${role} nodes architecture..."
  expected="$(normalize_arch "${3}")"
  ret_arch="$(normalize_arch "$(get_nodes_arch_by_label "${label}")")"
  if ! [ "$ret_arch" == "${expected}" ]; then
    echo "[ERROR] The expected ${role} architecture (${expected}) is different than the rendered one ($ret_arch)."
    debug
    return 1
  fi
  echo "[INFO] ${role} architecture verified ($ret_arch == ${expected})."
}

verify_arch_by_role_label "control plane" "node-role.kubernetes.io/master" \
  "$(yq-v4 -r '.controlPlane.architecture // "'"${CONTROL_ARCH}"'"' "${SHARED_DIR}/install-config.yaml")"
verify_arch_by_role_label "workers" "node-role.kubernetes.io/worker" \
  "$(yq-v4 -r '.compute[] | select(.name == "worker") | .architecture // "'"${COMPUTE_ARCH}"'"' "${SHARED_DIR}/install-config.yaml")"
echo "[INFO] All nodes have the expected architecture."
oc get nodes -owide
