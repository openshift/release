#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Detect node IP subnets from mgmt cluster ($SHARED_DIR/kubeconfig) and infra
# cluster ($SHARED_DIR/infra-kubeconfig), and write METALLB_MGMT_IPS and
# METALLB_MGMT_IPS_INFRA into SHARED_DIR so the subsequent metallb-oz and
# metallb-oz-infra steps can consume them.
#
# MGMT_IPS is in the range of mgmt cluster node IPs (.53).
# INFRA_IPS is in the range of infra cluster node IPs (.54).

MGMT_KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ ! -f "${MGMT_KUBECONFIG}" ]]; then
  echo "ERROR: mgmt kubeconfig not found at ${MGMT_KUBECONFIG}"
  exit 1
fi

MGMT_NODE_IP=$(KUBECONFIG="${MGMT_KUBECONFIG}" oc get nodes -o wide --no-headers 2>/dev/null \
  | awk '{print $6}' | grep -v '^$' | head -1)

if [[ -z "${MGMT_NODE_IP}" ]]; then
  echo "ERROR: could not detect any node IP from mgmt kubeconfig"
  exit 1
fi

echo "Detected mgmt node IP: ${MGMT_NODE_IP}"

if [[ "${MGMT_NODE_IP}" == 192.168.126.* ]]; then
  MGMT_IPS="192.168.126.53-192.168.126.53"
elif [[ "${MGMT_NODE_IP}" == 192.168.1.* ]]; then
  MGMT_IPS="192.168.1.53-192.168.1.53"
elif [[ "${MGMT_NODE_IP}" == 192.168.2.* ]]; then
  MGMT_IPS="192.168.2.53-192.168.2.53"
elif [[ "${MGMT_NODE_IP}" == 192.168.3.* ]]; then
  MGMT_IPS="192.168.3.53-192.168.3.53"
else
  echo "ERROR: unrecognised mgmt node IP subnet '${MGMT_NODE_IP}' — add a mapping for this environment"
  exit 1
fi

INFRA_KUBECONFIG="${SHARED_DIR}/infra-kubeconfig"
if [[ ! -f "${INFRA_KUBECONFIG}" ]]; then
  echo "ERROR: infra kubeconfig not found at ${INFRA_KUBECONFIG}"
  exit 1
fi

INFRA_NODE_IP=$(KUBECONFIG="${INFRA_KUBECONFIG}" oc get nodes -o wide --no-headers 2>/dev/null \
  | awk '{print $6}' | grep -v '^$' | head -1)

if [[ -z "${INFRA_NODE_IP}" ]]; then
  echo "ERROR: could not detect any node IP from infra kubeconfig"
  exit 1
fi

echo "Detected infra node IP: ${INFRA_NODE_IP}"

if [[ "${INFRA_NODE_IP}" == 192.168.126.* ]]; then
  INFRA_IPS="192.168.126.54-192.168.126.54"
elif [[ "${INFRA_NODE_IP}" == 192.168.1.* ]]; then
  INFRA_IPS="192.168.1.54-192.168.1.54"
elif [[ "${INFRA_NODE_IP}" == 192.168.2.* ]]; then
  INFRA_IPS="192.168.2.54-192.168.2.54"
elif [[ "${INFRA_NODE_IP}" == 192.168.3.* ]]; then
  INFRA_IPS="192.168.3.54-192.168.3.54"
else
  echo "ERROR: unrecognised infra node IP subnet '${INFRA_NODE_IP}' — add a mapping for this environment"
  exit 1
fi

echo "METALLB_MGMT_IPS=${MGMT_IPS}"
echo "METALLB_MGMT_IPS_INFRA=${INFRA_IPS}"

printf '%s' "${MGMT_IPS}"  > "${SHARED_DIR}/METALLB_MGMT_IPS"
printf '%s' "${INFRA_IPS}" > "${SHARED_DIR}/METALLB_MGMT_IPS_INFRA"
