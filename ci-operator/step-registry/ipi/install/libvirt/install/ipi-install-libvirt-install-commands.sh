#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function read_shared_dir() {
  local key="$1"
  yq r "${SHARED_DIR}/cluster-config.yaml" "$key"
}

function populate_artifact_dir() {
  set +e
  echo "Copying log bundle..."
  cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
  echo "Removing REDACTED info from log..."
  sed '
    s/password: .*/password: REDACTED/;
    s/X-Auth-Token.*/X-Auth-Token REDACTED/;
    s/UserData:.*,/UserData: REDACTED,/;
    ' "${dir}/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"
}

function prepare_next_steps() {
  set +e
  echo "Setup phase finished, prepare env for next steps"
  populate_artifact_dir
  echo "Copying required artifacts to shared dir"
  #Copy the auth artifacts to shared dir for the next steps
  cp \
      -t "${SHARED_DIR}" \
      "${dir}/auth/kubeconfig" \
      "${dir}/auth/kubeadmin-password" \
      "${dir}/metadata.json"
}

trap 'prepare_next_steps' EXIT TERM
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=$(read_shared_dir 'OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE')
if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp
export KUBECONFIG=${HOME}/.kube/config

dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

# Increase log verbosity and ensure it gets saved
export TF_LOG=DEBUG
export TF_LOG_PATH=${ARTIFACT_DIR}/terraform.log

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

echo "Creating manifest"
mock-nss.sh openshift-install create manifests --dir=${dir}
sed -i '/^  channel:/d' ${dir}/manifests/cvo-overrides.yaml

# Bumping up reserve memory for worker for ppc64le
if [ "${ARCH}" == "ppc64le" ]; then
  cat > "${dir}/manifests/manifest-reserve-sys-mem-kubeletconfig.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: reserve-sys-mem
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/worker: ""
  kubeletConfig: 
    systemReserved:
      memory: 2Gi
EOF
fi

# Bump the libvirt masters memory to 16GB
export TF_VAR_libvirt_master_memory=${MASTER_MEMORY}
ls ${dir}/openshift
for ((i=0; i<${MASTER_REPLICAS}; i++))
do
  yq write --inplace ${dir}/openshift/99_openshift-cluster-api_master-machines-${i}.yaml spec.providerSpec.value[domainMemory] ${MASTER_MEMORY}
  yq write --inplace ${dir}/openshift/99_openshift-cluster-api_master-machines-${i}.yaml spec.providerSpec.value.volume[volumeSize] ${MASTER_DISK}
done
# Bump the libvirt workers memory to 16GB
yq write --inplace ${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml spec.template.spec.providerSpec.value[domainMemory] ${WORKER_MEMORY}
# Bump the libvirt workers disk to to 30GB
yq write --inplace ${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml spec.template.spec.providerSpec.value.volume[volumeSize] ${WORKER_DISK}

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" -name "manifest_*.yml" -print0)

echo "Installing cluster"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
mock-nss.sh openshift-install create cluster --dir="${dir}" --log-level=debug 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
openshift_install="$!"

# While openshift-install is running...
# Block for injecting DNS below release 4.8
# TO-DO Remove after 4.7 EOL
if [ "${BRANCH}" == "4.7" ] || [ "${BRANCH}" == "4.6" ]; then
  REMOTE_LIBVIRT_URI=$(read_shared_dir 'REMOTE_LIBVIRT_URI')
  CLUSTER_NAME=$(read_shared_dir 'CLUSTER_NAME')

  i=0
  while kill -0 $openshift_install 2> /dev/null; do
    sleep 60
    echo "Polling libvirt for network, attempt #$((++i))"
    LIBVIRT_NETWORK=$(mock-nss.sh virsh --connect "${REMOTE_LIBVIRT_URI}" net-list --name | grep "${CLUSTER_NAME::21}" || true)
    if [[ -n "${LIBVIRT_NETWORK}" ]]; then
      echo "Libvirt network found. Injecting worker DNS records."
      mock-nss.sh virsh --connect "${REMOTE_LIBVIRT_URI}" net-update --network "${LIBVIRT_NETWORK}" --command add-last --section dns-host --xml "$(< ${SHARED_DIR}/worker-hostrecords.xml)"
      break
    fi
  done
fi
wait "${openshift_install}"

# Add a step to wait for installation to complete, in case the cluster takes longer to create than the default time of 30 minutes.
mock-nss.sh openshift-install --dir=${dir} --log-level=debug wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"
ret="$?"

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

exit "$ret"
