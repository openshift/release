#!/usr/bin/env bash

set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
MICROSHIFT_URL="https://${IP_ADDRESS}:6443"
CONFORMANCE_SKIP="/tmp/skip.txt"
touch "${CONFORMANCE_SKIP}"
CONFORMANCE_TEST_LIST="/tmp/tests.txt"
touch "${CONFORMANCE_TEST_LIST}"
export STATIC_CONFIG_MANIFEST_DIR=/tmp/manifests
mkdir "${STATIC_CONFIG_MANIFEST_DIR}"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"


if [ -f "${SHARED_DIR}/conformance-skip.txt" ]; then
    cp ${SHARED_DIR}/conformance-skip.txt "${CONFORMANCE_SKIP}"
fi
while read -r test; do
    grep -F "$test" "${CONFORMANCE_SKIP}" > /dev/null || echo "$test" >> "${CONFORMANCE_TEST_LIST}"
done < <(openshift-tests run openshift/conformance --dry-run --provider none 2>/dev/null | egrep '^"\[')
cp "${CONFORMANCE_TEST_LIST}" "${ARTIFACT_DIR}/tests.txt"

cat > "${STATIC_CONFIG_MANIFEST_DIR}/infrastructure.yaml" <<EOF
apiVersion: "config.openshift.io/v1"
kind: Infrastructure
metadata:
  name: cluster
spec:
  platformSpec:
    type: None
status:
  apiServerURL: ${MICROSHIFT_URL}
  controlPlaneTopology: SingleReplica
  infrastructureTopology: SingleReplica
  platform: None
  platformStatus:
    type: None
EOF
cat > "${STATIC_CONFIG_MANIFEST_DIR}/network.yaml" <<EOF
apiVersion: config.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  networkType: OVNKubernetes
status:
  networkType: OVNKubernetes
EOF

openshift-tests run openshift/conformance -f "${CONFORMANCE_TEST_LIST}" -v 2 --provider=none -o "${ARTIFACT_DIR}/e2e.log" --junit-dir "${ARTIFACT_DIR}/junit"
