#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

source "${SHARED_DIR}/nutanix_context.sh"
CLUSTER_NAME=$(<"${SHARED_DIR}"/cluster-name.txt)

echo "Creating agent image..."
export WORK_DIR=/tmp/installer
mkdir "${WORK_DIR}"

cp -t "${WORK_DIR}" "${SHARED_DIR}"/{install-config.yaml,agent-config.yaml}

echo "Installing from initial release $OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"
  oc adm release extract -a "${SHARED_DIR}"/pull-secrets "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
  --command=openshift-install --to="/tmp" || exit 1

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

grep -v "password\|username\|pullSecret" "${SHARED_DIR}/install-config.yaml" > "${ARTIFACT_DIR}/install-config.yaml" || true
grep -v "password\|username\|pullSecret" "${SHARED_DIR}/agent-config.yaml" > "${ARTIFACT_DIR}/agent-config.yaml" || true

/tmp/openshift-install agent create image --dir="${WORK_DIR}" --log-level debug

echo "Copying kubeconfig to the shared directory..."
cp -t "${SHARED_DIR}" \
  "${WORK_DIR}/auth/kubeadmin-password" \
  "${WORK_DIR}/auth/kubeconfig"

export AGENT_IMAGE="agent.x86_64_${CLUSTER_NAME}.iso"
mv "${WORK_DIR}"/agent.x86_64.iso "${WORK_DIR}"/"${AGENT_IMAGE}"

export HOME=/output
cd ansible-files
ansible-playbook nutanix_provision_vm.yml

## Monitor for `bootstrap-complete`
echo "$(date -u --rfc-3339=seconds) - Monitoring for bootstrap to complete"
/tmp/openshift-install --dir="${WORK_DIR}" agent wait-for bootstrap-complete &

if ! wait $!; then
  echo "ERROR: Bootstrap failed. Aborting execution."
  exit 1
fi

## Monitor for cluster completion
echo "$(date -u --rfc-3339=seconds) - Monitoring for cluster completion..."

# When using line-buffering there is a potential issue that the buffer is not filled (or no new line) and this waits forever
# or in our case until the four hour CI timer is up.
/tmp/openshift-install --dir="${WORK_DIR}" agent wait-for install-complete --log-level=debug 2>&1 | stdbuf -o0 grep -v password &

if ! wait "$!"; then
  echo "ERROR: Installation failed. Aborting execution."
  exit 1
fi

echo "Ensure that all the cluster operators remain stable and ready until OCPBUGS-18658 is fixed."
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=60m