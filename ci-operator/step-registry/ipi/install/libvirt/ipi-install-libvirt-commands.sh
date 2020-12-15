#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Install-libvirt"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi

echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME}/${BUILD_ID}
export HOME=/tmp

case "${CLUSTER_TYPE}" in
#aws) export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred;;
#azure4) export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json;;
#gcp) export GOOGLE_CLOUD_KEYFILE_JSON=${CLUSTER_PROFILE_DIR}/gce.json;;
#kubevirt) export KUBEVIRT_KUBECONFIG=${HOME}/.kube/config;;
#vsphere) ;;
#openstack) export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml ;;
#openstack-vexxhost) export OS_CLIENT_CONFIG_FILE=${CLUSTER_PROFILE_DIR}/clouds.yaml ;;
libvirt-s390x) export KUBECONFIG=${HOME}/.kube/config ;;
libvirt-ppc64le) export KUBECONFIG=${HOME}/.kube/config ;;
*) echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
esac

dir=/tmp/installer
mkdir "${dir}/"
cp "${SHARED_DIR}/install-config.yaml" "${dir}/"

# move private key to ~/.ssh/ so that installer can use it to gather logs on
# bootstrap failure
mkdir -p ~/.ssh
cp "${SSH_PRIV_KEY_PATH}" ~/.ssh/

#openshift-install --dir="${dir}" create manifests &
#wait "$!"

# Increase log verbosity and ensure it gets saved
export TF_LOG=DEBUG
export TF_LOG_PATH=${ARTIFACT_DIR}/terraform.log

echo "Creating manifest"
mock-nss.sh openshift-install create manifests --dir=${dir}
sed -i '/^  channel:/d' ${dir}/manifests/cvo-overrides.yaml
# Bump the libvirt masters memory to 16GB
export TF_VAR_libvirt_master_memory=16384
ls ${dir}/openshift
for ((i=0; i<$MASTER_REPLICAS; i++))
do
  yq write --inplace ${dir}/openshift/99_openshift-cluster-api_master-machines-${i}.yaml spec.providerSpec.value[domainMemory] 16384
done
# Bump the libvirt workers memory to 8GB
yq write --inplace ${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml spec.template.spec.providerSpec.value[domainMemory] 8192
# Bump the libvirt workers disk to to 30GB
yq write --inplace ${dir}/openshift/99_openshift-cluster-api_worker-machineset-0.yaml spec.template.spec.providerSpec.value.volume[volumeSize] 32212254720

while IFS= read -r -d '' item
do
  manifest="$( basename "${item}" )"
  cp "${item}" "${dir}/manifests/${manifest##manifest_}"
done <   <( find "${SHARED_DIR}" -name "manifest_*.yml" -print0)


echo "Installing cluster"
mock-nss.sh openshift-install create cluster --dir=${dir} --log-level=debug || true &
openshift_install="$!"
sed -i '/^  channel:/d' "${dir}/manifests/cvo-overrides.yaml"

# Password for the cluster gets leaked in the installer logs and hence removing them.
sed -i 's/password: .*/password: REDACTED"/g' ${ARTIFACT_DIR}/installer/.openshift_install.log
# While openshift-install is running...
i=0
while kill -0 $openshift_install 2> /dev/null; do
  sleep 60
  echo "Polling libvirt for network, attempt #$((++i))"
  LIBVIRT_NETWORK=$(mock-nss.sh virsh --connect "${REMOTE_LIBVIRT_URI}" net-list --name | grep "${NAMESPACE}-${JOB_NAME_HASH}" || true)
  if [[ -n "${LIBVIRT_NETWORK}" ]]; then
      cat > ${dir}/worker-hostrecords.xml << EOF
<host ip='192.168.${CLUTER_SUBNET}.51'>
  <hostname>alertmanager-main-openshift-monitoring.apps.${CLUSTER_NAME}.${LEASED_RESOURCE}</hostname>
  <hostname>console-openshift-console.apps.${CLUSTER_NAME}.${LEASED_RESOURCE}</hostname>
  <hostname>downloads-openshift-console.apps.${CLUSTER_NAME}.${LEASED_RESOURCE}</hostname>
  <hostname>grafana-openshift-monitoring.apps.${CLUSTER_NAME}.${LEASED_RESOURCE}</hostname>
  <hostname>oauth-openshift.apps.${CLUSTER_NAME}.${LEASED_RESOURCE}</hostname>
  <hostname>prometheus-k8s-openshift-monitoring.apps.${CLUSTER_NAME}.${LEASED_RESOURCE}</hostname>
</host>
EOF
      echo "Libvirt network found. Injecting worker DNS records."
      mock-nss.sh virsh --connect "${REMOTE_LIBVIRT_URI}" net-update --network "${LIBVIRT_NETWORK}" --command add-last --section dns-host --xml "$(< ${dir}/worker-hostrecords.xml)"
      break
  fi
done
wait "${openshift_install}"
# Add a step to wait for installation to complete, in case the cluster takes longer to create than the default time of 30 minutes.
mock-nss.sh openshift-install --dir=${dir} --log-level=debug wait-for install-complete 2>&1 &
wait "$!"

#TF_LOG=debug openshift-install --dir="${dir}" create cluster 2>&1 | grep --line-buffered -v password &



set +e
wait "$!"
ret="$?"
cp "${dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null
set -e

sed 's/password: .*/password: REDACTED/' "${dir}/.openshift_install.log" >"${ARTIFACT_DIR}/.openshift_install.log"
cp \
    -t "${SHARED_DIR}" \
    "${dir}/auth/kubeconfig" \
    "${dir}/auth/kubeadmin-password" \
    "${dir}/metadata.json"
exit "$ret"
