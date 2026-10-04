#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

if [ -s "${SHARED_DIR}/proxy-conf.sh" ]; then
  echo "Sourcing proxy configuration"
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/proxy-conf.sh"
fi

EXPECTED_IMAGE=""
if [[ -s "${SHARED_DIR}/ovs-doca-osimage-reference" ]]; then
  EXPECTED_IMAGE="$(cat "${SHARED_DIR}/ovs-doca-osimage-reference")"
  echo "Expecting nodes to run: ${EXPECTED_IMAGE}"
else
  echo "No ${SHARED_DIR}/ovs-doca-osimage-reference found; skipping the image reference check."
fi

echo "Waiting for the ${OVS_DOCA_MCP} MachineConfigPool to settle..."
if ! oc wait "mcp/${OVS_DOCA_MCP}" --for='condition=Updated=True' --timeout=30m; then
  echo "ERROR: the ${OVS_DOCA_MCP} pool did not reach Updated=True."
  oc get mcp,nodes -o wide
  oc describe "mcp/${OVS_DOCA_MCP}"
  exit 1
fi

mapfile -t NODES < <(oc get nodes -l "node-role.kubernetes.io/${OVS_DOCA_MCP}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "ERROR: no nodes found with role ${OVS_DOCA_MCP}."
  oc get nodes --show-labels
  exit 1
fi
echo "Validating ${#NODES[@]} node(s): ${NODES[*]}"

failed=0

for node in "${NODES[@]}"; do
  echo ""
  echo "=== ${node} ==="

  if [[ -n "${EXPECTED_IMAGE}" ]]; then
    actual_image="$(oc get "node/${node}" -o jsonpath='{.metadata.annotations.machineconfiguration\.openshift\.io/currentImage}' 2>/dev/null || true)"
    if [[ -z "${actual_image}" ]]; then
      # Clusters that pivot via a MachineConfig osImageURL rather than on-cluster layering
      # report the running image through rpm-ostree instead of the currentImage annotation.
      actual_image="$(oc debug "node/${node}" -q -- chroot /host rpm-ostree status --json 2>/dev/null \
        | jq -r '.deployments[0]["container-image-reference"] // empty' | sed 's|^ostree-unverified-registry:||;s|^ostree-image-signed:||;s|^docker://||' || true)"
    fi
    echo "osImage in use: ${actual_image:-<unknown>}"
    if [[ "${actual_image}" != *"${EXPECTED_IMAGE##*@}"* ]]; then
      echo "ERROR: ${node} is not running the expected layered image ${EXPECTED_IMAGE}."
      failed=1
    fi
  fi

  echo "Installed DOCA packages:"
  if ! oc debug "node/${node}" -q -- chroot /host rpm -q ${OVS_DOCA_PACKAGES}; then
    echo "ERROR: one or more expected packages are missing on ${node}."
    failed=1
  fi

  for absent in ${OVS_DOCA_ABSENT_PACKAGES}; do
    # rpm -qa output is matched against '<prefix>[0-9]' and bare '<prefix>' so that stock
    # openvswitch3.4 is caught while doca-openvswitch is not.
    if leftovers="$(oc debug "node/${node}" -q -- chroot /host rpm -qa --qf '%{NAME}\n' 2>/dev/null | grep -E "^${absent}([0-9].*)?$" || true)"; then
      if [[ -n "${leftovers}" ]]; then
        echo "ERROR: ${node} still has conflicting package(s): ${leftovers}"
        failed=1
      fi
    fi
  done
done

echo ""
if [[ ${failed} -ne 0 ]]; then
  echo "DOCA node package validation FAILED."
  oc get mcp,nodes -o wide
  exit 1
fi

echo "DOCA node package validation passed on all ${#NODES[@]} ${OVS_DOCA_MCP} node(s)."
