#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi


function oinst() {
  /tmp/openshift-install --dir="${INSTALL_DIR}" --log-level=debug "${@}" 2>&1 | grep\
   --line-buffered -v 'password\|X-Auth-Token\|UserData:'
}

function get_ready_nodes_count() {
  oc get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | \
    grep -c -E ",True$"
}



function update_image_registry() {
  while ! oc patch configs.imageregistry.operator.openshift.io cluster --type merge \
                 --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'; do
    echo "Sleeping before retrying to patch the image registry config..."
    sleep 60
  done
}

PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
INSTALL_DIR="/tmp/installer"
KUBECONFIG_DIR="/tmp/installer/auth"
mkdir -p "${INSTALL_DIR}"
mkdir -p "${KUBECONFIG_DIR}"

echo "Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
oc adm release extract -a "$PULL_SECRET_PATH" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" \
   --command=openshift-install --to=/tmp

export KUBECONFIG="$KUBECONFIG_DIR/kubeconfig"

echo -e "\nCopying KUBECONFIG and YAML files from SHARED_DIR to INSTALL_DIR..."
cp "${SHARED_DIR}/kubeconfig" "${KUBECONFIG_DIR}/"
cp "${SHARED_DIR}/kubeadmin-password" "${KUBECONFIG_DIR}/"
cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"
cp "${SHARED_DIR}/agent-config.yaml" "${INSTALL_DIR}/"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

echo "Launching 'wait-for bootstrap-complete' installation step....."
# The installer uses the rendezvous IP for checking the bootstrap phase.
# The rendezvous IP is in the internal net in our lab.
# Let's use a proxy here as the internal net is not routable from the container running the installer.
proxy="$(<"${CLUSTER_PROFILE_DIR}/proxy")"
http_proxy="${proxy}" https_proxy="${proxy}" HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}" \
  oinst agent wait-for bootstrap-complete 2>&1 &
if ! wait $!; then
  # TODO: gather logs??
  echo "ERROR: Bootstrap failed. Aborting execution."
  exit 1
fi

update_image_registry &
echo -e "\nLaunching 'wait-for install-complete' installation step....."
http_proxy="${proxy}" https_proxy="${proxy}" HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}" \
  oinst agent wait-for install-complete &
if ! wait "$!"; then
  echo "ERROR: Installation failed. Aborting execution."
  # TODO: gather logs??
  exit 1
fi
