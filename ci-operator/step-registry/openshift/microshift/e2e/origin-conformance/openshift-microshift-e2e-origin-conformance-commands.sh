#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
trap_subprocesses_on_term

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
MICROSHIFT_URL="https://${IP_ADDRESS}:6443"
CONFORMANCE_SKIP="/tmp/skip.txt"
touch "${CONFORMANCE_SKIP}"
CONFORMANCE_TEST_LIST="/tmp/tests.txt"
touch "${CONFORMANCE_TEST_LIST}"
export STATIC_CONFIG_MANIFEST_DIR=/tmp/manifests
mkdir "${STATIC_CONFIG_MANIFEST_DIR}"
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# In order for openshift-tests to pull external binary images from the
# payload, we need access enabled to the images on the build farm. In
# order to do that, we need to unset the KUBECONFIG so we talk to the
# build farm, not the cluster under test.
echo "Granting access for image pulling from the build farm..."
KUBECONFIG_BAK=$KUBECONFIG
unset KUBECONFIG
oc adm policy add-role-to-group system:image-puller system:unauthenticated --namespace "${NAMESPACE}"
export KUBECONFIG=$KUBECONFIG_BAK

# The base image for this step is incapable of ssh-ing to MicroShift's VM because
# of user configuration. Since this image comes from promotion of origin we would
# like to leave it untouched. The skip list is within MicroShift's code, which is
# inside the VM that we need to ssh. Use the previous step (openshift-microshift-infra-conformance-setup)
# to put the list in the $SHARED_DIR so its available for any other step that may
# need it.
if [ -f "${SHARED_DIR}/conformance-skip.txt" ]; then
    cp ${SHARED_DIR}/conformance-skip.txt "${CONFORMANCE_SKIP}"
fi

# Remove skipped tests from current complete test list. This will automatically take new
# tests in and we shall see whether they fail in the very first run in which they are included.
# The test list belongs to MicroShift repo to control this by release.
while read -r test; do
    grep -F "$test" "${CONFORMANCE_SKIP}" > /dev/null || echo "$test" >> "${CONFORMANCE_TEST_LIST}"
done < <(openshift-tests run "${TEST_SUITE}" --dry-run --provider none 2>/dev/null | egrep '^"\[')
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

openshift-tests run "${TEST_SUITE}" -f "${CONFORMANCE_TEST_LIST}" -v 2 --provider=none -o "${ARTIFACT_DIR}/e2e.log" --junit-dir "${ARTIFACT_DIR}/junit"
