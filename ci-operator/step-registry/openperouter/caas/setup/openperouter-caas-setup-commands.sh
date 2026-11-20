#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ openperouter caas setup ************"

echo "DEPLOYMENT_MODE: ${DEPLOYMENT_MODE:-standard}"
echo "DATAPLANE: ${DATAPLANE:-kernel}"

# SHARED_DIR is the CI-provided workspace shared by all steps in the workflow.
# The ofcir-acquire step writes packet-conf.sh there; it defines the leased
# host's IP and SSHOPTS and verifies root SSH access.
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

REPO_DIR="/opt/openperouterday0openshift"
PULL_SECRET="/opt/pull_secret.json"

echo "### Copying pull secret to remote host"
# Disable tracing due to secret handling (see AGENTS.md security best practices).
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
if [[ ! -f "${CLUSTER_PROFILE_DIR}/pull-secret" ]]; then
  echo "ERROR: ${CLUSTER_PROFILE_DIR}/pull-secret not found"
  exit 1
fi
ssh "${SSHOPTS[@]}" "root@${IP}" "mkdir -p /opt"
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:${PULL_SECRET}"
$WAS_TRACING && set -x

echo "### Generating remote setup script with substituted variables"
remote_script="$(mktemp /tmp/openperouter-caas-setup.XXXXXX.sh)"
# shellcheck disable=SC2016
cat << REMOTE_SETUP > "${remote_script}"
set -xeo pipefail

echo "### Cloning ${OPENPEROUTER_DAY0_REPO} (branch: ${OPENPEROUTER_DAY0_BRANCH}) to ${REPO_DIR}"
git clone --depth 1 --branch "${OPENPEROUTER_DAY0_BRANCH}" "${OPENPEROUTER_DAY0_REPO}" "${REPO_DIR}"

echo "### Ensuring an SSH keypair exists for appliance generation"
if [[ ! -f /root/.ssh/id_rsa ]]; then
  ssh-keygen -t rsa -b 2048 -f /root/.ssh/id_rsa -N ''
fi

echo "### Installing required packages"
yum install -y butane coreos-installer podman pip go ansible-core jq

echo "### Building appliance and config image"
pushd "${REPO_DIR}/srv6fullconfig"
SSH_PUB_KEY="\$(cat /root/.ssh/id_rsa.pub)" appliance/generate_appliance.sh "${PULL_SECRET}"
SSH_PUB_KEY="\$(cat /root/.ssh/id_rsa.pub)" configimage/generate_config_image.sh "${PULL_SECRET}"
popd

echo "### Deploying the virtual environment"
"${REPO_DIR}/site/vmlab/lab-up.sh" \
  "${REPO_DIR}/srv6fullconfig/appliance/appliance.iso" \
  "${REPO_DIR}/srv6fullconfig/configimage/configimage/agentconfig.noarch.iso"

echo "### Waiting for the OpenShift cluster to become available"
export KUBECONFIG="${REPO_DIR}/srv6fullconfig/configimage/configimage/auth/kubeconfig"

deadline=\$(( SECONDS + ${VERIFY_TIMEOUT_MIN:-60} * 60 ))
while (( SECONDS < deadline )); do
  echo "=== cluster status at \$(date -u '+%Y-%m-%d %H:%M:%S UTC') ==="
  ip vrf exec red oc get nodes || true
  ip vrf exec red oc get clusterversion || true
  ip vrf exec red oc get co || true

  available="\$(ip vrf exec red oc get clusterversion -o json 2>/dev/null | jq -r '.items[0].status.conditions[] | select(.type=="Available").status' || true)"
  progressing="\$(ip vrf exec red oc get clusterversion -o json 2>/dev/null | jq -r '.items[0].status.conditions[] | select(.type=="Progressing").status' || true)"
  echo "clusterversion: Available=\${available:-<unset>} Progressing=\${progressing:-<unset>}"

  if [[ "\${available}" == "True" && "\${progressing}" == "False" ]]; then
    echo "### OpenShift cluster is ready"
    exit 0
  fi

  sleep "${VERIFY_INTERVAL_SEC:-60}"
done

echo "ERROR: OpenShift cluster did not become ready within ${VERIFY_TIMEOUT_MIN:-60} minutes"
exit 1
REMOTE_SETUP

echo "### Copying remote setup script to remote host"
scp "${SSHOPTS[@]}" "${remote_script}" "root@${IP}:/tmp/openperouter-caas-setup.sh"

echo "### Running remote setup (clone, appliance build, lab-up, cluster verification)"
set +e
ssh "${SSHOPTS[@]}" "root@${IP}" bash /tmp/openperouter-caas-setup.sh
test_rc="$?"

rm -f "${remote_script}"

if [[ "${test_rc}" -ne 0 ]]; then
  echo "### openperouter caas setup FAILED"
  exit "${test_rc}"
fi

# TODO: further setup steps follow here - TBD.

echo "### openperouter caas setup done"
