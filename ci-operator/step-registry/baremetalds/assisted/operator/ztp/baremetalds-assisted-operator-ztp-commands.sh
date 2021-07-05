#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator ztp command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

# Copy additional dev-script variables, if present
if [[ -e "${SHARED_DIR}/ds-vars.conf" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/ds-vars.conf" "root@${IP}:ds-vars.conf"
fi

# Copy job variables to the packet server
echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE=${OPENSHIFT_INSTALL_RELEASE_IMAGE}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_OPENSHIFT_INSTALL_RELEASE_IMAGE=${ASSISTED_OPENSHIFT_INSTALL_RELEASE_IMAGE}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_NAMESPACE=${ASSISTED_NAMESPACE}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_CLUSTER_NAME=${ASSISTED_CLUSTER_NAME}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_CLUSTER_DEPLOYMENT_NAME=${ASSISTED_CLUSTER_DEPLOYMENT_NAME}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_INFRAENV_NAME=${ASSISTED_INFRAENV_NAME}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_PRIVATEKEY_NAME=${ASSISTED_PRIVATEKEY_NAME}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_PULLSECRET_NAME=${ASSISTED_PULLSECRET_NAME}" >> /tmp/assisted-vars.conf
echo "export ASSISTED_PULLSECRET_JSON=${ASSISTED_PULLSECRET_JSON}" >> /tmp/assisted-vars.conf
scp "${SSHOPTS[@]}" "/tmp/assisted-vars.conf" "root@${IP}:assisted-vars.conf"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<"EOF" |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

set -xeo pipefail

source /root/ds-vars.conf
source /root/assisted-vars.conf

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

REPO_DIR="/home/assisted-service"
if [ ! -d "${REPO_DIR}" ]; then
  mkdir -p "${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "${REPO_DIR}"
fi

cd "${REPO_DIR}/deploy/operator/ztp/"
echo "### Deploying SNO spoke cluster..."
export DISCONNECTED="${DISCONNECTED:-}"
export EXTRA_BAREMETALHOSTS_FILE="/root/dev-scripts/${EXTRA_BAREMETALHOSTS_FILE}"
./deploy_spoke_cluster.sh

EOF
