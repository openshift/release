#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Detect the node IP subnet from the infra cluster kubeconfig and write
# METALLB_MGMT_IPS and METALLB_MGMT_IPS_INFRA into SHARED_DIR so the
# subsequent metallb-oz and metallb-oz-infra steps can consume them.
#
# Subnet → IP mapping (OZ libvirt environments):
#   192.168.2.x  →  METALLB_MGMT_IPS=192.168.2.53-192.168.2.53
#                   METALLB_MGMT_IPS_INFRA=192.168.2.54-192.168.2.54
#   192.168.3.x  →  METALLB_MGMT_IPS=192.168.3.53-192.168.3.53
#                   METALLB_MGMT_IPS_INFRA=192.168.3.54-192.168.3.54

INFRA_KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"
if [[ ! -f "${INFRA_KUBECONFIG}" ]]; then
  echo "ERROR: infra kubeconfig not found at ${INFRA_KUBECONFIG}"
  exit 1
fi

NODE_IP=$(KUBECONFIG="${INFRA_KUBECONFIG}" oc get nodes -o wide --no-headers 2>/dev/null \
  | awk '{print $6}' | grep -v '^$' | head -1)

if [[ -z "${NODE_IP}" ]]; then
  echo "ERROR: could not detect any node IP from infra-kubeconfig"
  exit 1
fi

echo "Detected infra node IP: ${NODE_IP}"

if [[ "${NODE_IP}" == 192.168.2.* ]]; then
  MGMT_IPS="192.168.2.53-192.168.2.53"
  INFRA_IPS="192.168.2.54-192.168.2.54"
elif [[ "${NODE_IP}" == 192.168.3.* ]]; then
  MGMT_IPS="192.168.3.53-192.168.3.53"
  INFRA_IPS="192.168.3.54-192.168.3.54"
else
  echo "ERROR: unrecognised node IP subnet '${NODE_IP}' — add a mapping for this environment"
  exit 1
fi

echo "METALLB_MGMT_IPS=${MGMT_IPS}"
echo "METALLB_MGMT_IPS_INFRA=${INFRA_IPS}"

printf '%s' "${MGMT_IPS}"  > "${SHARED_DIR}/METALLB_MGMT_IPS"
printf '%s' "${INFRA_IPS}" > "${SHARED_DIR}/METALLB_MGMT_IPS_INFRA"
