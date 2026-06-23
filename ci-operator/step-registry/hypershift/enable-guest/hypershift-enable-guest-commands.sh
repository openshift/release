#!/bin/bash

set -euo pipefail

if [ ! -f "${SHARED_DIR}/nested_kubeconfig" ]; then
  echo "ERROR: ${SHARED_DIR}/nested_kubeconfig not found, cannot switch to guest cluster" >&2
  exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

console_host="$(oc --kubeconfig="${SHARED_DIR}/nested_kubeconfig" -n openshift-console get routes console -o=jsonpath='{.spec.host}')"
if [ -z "${console_host}" ]; then
  echo "ERROR: Failed to determine hosted cluster console route host" >&2
  exit 1
fi
echo "https://${console_host}" > "${SHARED_DIR}/hostedcluster_console.url"
echo "hostedcluster_console.url path:${SHARED_DIR}/hostedcluster_console.url"
cat "${SHARED_DIR}/hostedcluster_console.url"

echo "switch kubeconfig"
cp "${SHARED_DIR}/kubeconfig" "${SHARED_DIR}/mgmt_kubeconfig"
cat "${SHARED_DIR}/nested_kubeconfig" > "${SHARED_DIR}/kubeconfig"
echo "hypershift-guest" > "${SHARED_DIR}/cluster-type"
