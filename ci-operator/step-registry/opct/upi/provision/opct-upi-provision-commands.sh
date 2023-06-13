#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

#
# Setting up Ansible Project and okd-installer Colellection
#

# Setup Ansible Project

cat <<EOF > ${SHARED_DIR}/env
export OCI_CLI_CONFIG_FILE=/var/run/vault/opct-splat/opct-oci-splat-user-config
export SSH_KEY_PATH=/var/run/vault/opct-splat/ssh-key
export OKD_INSTALLER_WORKDIR=/tmp/okd-installer
export ANSIBLE_CONFIG=${SHARED_DIR}/ansible.cfg
export ANSIBLE_REMOTE_TMP="/tmp/ansible-tmp-remote"
export ANSIBLE_LOG_PATH=/tmp/okd-installer/opct-runner.log
export CLUSTER_REGION=$CLUSTER_REGION
export CLUSTER_NAME=${PROVIDER_NAME}-ci
export VARS_FILE="${SHARED_DIR}/okd_installer-vars.yaml"
export CLUSTER_VERSION="${CLUSTER_VERSION:-'4.14.0-ec.3'}"
EOF
source ${SHARED_DIR}/env

mkdir -p $OKD_INSTALLER_WORKDIR
cat <<EOF > ${ANSIBLE_CONFIG}
[defaults]
local_tmp=${OKD_INSTALLER_WORKDIR}/tmp-local
callbacks_enabled=ansible.posix.profile_roles,ansible.posix.profile_tasks
hash_behavior=merge

[inventory]
enable_plugins = yaml, ini

[callback_profile_tasks]
task_output_limit=1000
sort_order=none
EOF

#
# Setting up OCI configuration
#
# Testing access to the cloud using Ansible
mkdir $HOME/.oci
ln -svf $OCI_CLI_CONFIG_FILE $HOME/.oci/config
oci_user_id=$(grep ^user "${OCI_CLI_CONFIG_FILE}" | awk -F '=' '{print$2}')
ansible localhost -m oracle.oci.oci_identity_user_facts -a user_id="${oci_user_id}" > /dev/null

## Linking oc
ansible-galaxy collection list

mkdir -p ${OKD_INSTALLER_WORKDIR}/bin
if [[ -f "/usr/bin/oc" ]]; then
    ln -svf "/usr/bin/oc" ${OKD_INSTALLER_WORKDIR}/bin/oc-linux-$CLUSTER_VERSION
    ln -svf "/usr/bin/oc" ${OKD_INSTALLER_WORKDIR}/bin/kubectl-linux-$CLUSTER_VERSION
else
    echo "Failed to find openshift client";
    # exit 1
fi

if [[ -f "/usr/bin/openshift-install" ]]; then
    ln -svf "/usr/bin/openshift-install" ${OKD_INSTALLER_WORKDIR}/bin/openshift-install-linux-$CLUSTER_VERSION
else
    echo "Failed to find openshift installer binary";
    # exit 1
fi

#
# Configuration
#

# Load Compartment IDs from secret
source /var/run/vault/opct-splat/opct-runner-vars-compartments


cat <<EOF > "${VARS_FILE}"
# Collection setup
collection_work_dir: ${OKD_INSTALLER_WORKDIR}

# Cluster setup
provider: $PROVIDER_NAME
cluster_name: ${CLUSTER_NAME}
config_cluster_region: ${CLUSTER_REGION}

oci_compartment_id: ${OCI_COMPARTMENT_ID}
oci_compartment_id_dns: ${OCI_COMPARTMENT_ID_DNS}
oci_compartment_id_image: ${OCI_COMPARTMENT_ID_IMAGE}

cluster_profile: ha
# destroy bootstrap isn't supported for oci (need to run destroy_all)
destroy_bootstrap: no

config_base_domain: $OPCT_DOMAIN
config_ssh_key: "$(cat ${SSH_KEY_PATH})"
config_pull_secret_file: "/var/run/ci-credentials/registry/.dockerconfigjson"

config_cluster_version: $CLUSTER_VERSION
version: $CLUSTER_VERSION

# Define the OS Image mirror
os_mirror: yes
os_mirror_from: stream_artifacts
os_mirror_stream:
  architecture: x86_64
  artifact: openstack
  format: qcow2.gz

os_mirror_to_provider: oci
os_mirror_to_oci:
  compartment_id: ${OCI_COMPARTMENT_ID_IMAGE}
  bucket: rhcos-images
  image_type: QCOW2

EOF


# Experimental
if [[ -n "${OPCT_EXPERIMENTAL_CUSTOM_RELEASE:-}" ]]; then
    cat <<EOF >> ${VARS_FILE}
# Platform External specifics (preview release with minimal changes)
#release_image: registry.ci.openshift.org/ocp/release
#release_version: 4.14.0-0.nightly-2023-06-23-011504
config_installer_environment:
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: "${OPCT_EXPERIMENTAL_CUSTOM_RELEASE}"
EOF

fi

# Platform External setup only
cat <<EOF >> ${VARS_FILE}

# Available manifest paches (runs after 'create manifest' stage)
config_patches:
- rm-capi-machines
- mc-kubelet-providerid
- deploy-oci-ccm
- deploy-oci-csi
- yaml_patch

# YAML Patches
cfg_patch_yaml_patch_specs:
  ## patch infra object to create External provider
  - manifest: /manifests/cluster-infrastructure-02-config.yml
    patch: '{"spec":{"platformSpec":{"type":"External","external":{"platformName":"oci"}}},"status":{"platform":"External","platformStatus":{"type":"External","external":{"cloudControllerManager":{"state":"External"}}}}}'

# MachineConfig to set the Kubelet environment. Will use this script to discover the ProviderID
cfg_patch_kubelet_providerid_script: |
    PROVIDERID=\$(curl -H "Authorization: Bearer Oracle" -sL http://169.254.169.254/opc/v2/instance/ | jq -r .id);

# Choose CCM deployment parameters
## Use patched manifests for OCP
oci_ccm_namespace: oci-cloud-controller-manager
## Use default manifests from github https://github.com/oracle/oci-cloud-controller-manager#deployment
## Note: that method is failing when copying the manifests 'as-is' in OCP. Need more investigation:
# oci_ccm_namespace: kube-system
# oci_ccm_version: v1.25.0

EOF

#
# Installing
#

ansible-playbook mtulio.okd_installer.create_all \
    -e cert_max_retries=30 \
    -e cert_wait_interval_sec=45 \
    -e @$VARS_FILE

# temp
echo "Approving remainging CSRs"
export KUBECONFIG=$OKD_INSTALLER_WORKDIR/clusters/${CLUSTER_NAME}/auth/kubeconfig
oc get csr
oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve || true

oc get nodes


cp $OKD_INSTALLER_WORKDIR/clusters/${CLUSTER_NAME}/auth/kubeconfig ${SHARED_DIR}/kubeconfig
cp $OKD_INSTALLER_WORKDIR/clusters/${CLUSTER_NAME}/cluster_state.json ${SHARED_DIR}/

cp ${SHARED_DIR}/env ${ARTIFACT_DIR}/env
cp ${ANSIBLE_CONFIG} ${ARTIFACT_DIR}/ansible.cfg
cp ${VARS_FILE} ${ARTIFACT_DIR}/cluster-vars-file.yaml

cp $OKD_INSTALLER_WORKDIR/clusters/${CLUSTER_NAME}/cluster_state.json ${SHARED_DIR}/
cp $OKD_INSTALLER_WORKDIR/clusters/${CLUSTER_NAME}/cluster_state.json ${ARTIFACT_DIR}/