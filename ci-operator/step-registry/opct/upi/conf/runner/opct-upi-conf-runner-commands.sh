#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

#
# Setting up Ansible Project and okd-installer Colellection
#

# Update shared vars with providers specific
cat >> "${SHARED_DIR}"/env << EOF
export CLUSTER_NAME=opct-ci
export CLUSTER_REGION=$CLUSTER_REGION
EOF

source "${SHARED_DIR}"/env
source "${SHARED_DIR}"/functions

cat >> "${VARS_FILE}" << EOF
# Collection setup
collection_work_dir: ${OKD_INSTALLER_WORKDIR}

# Cluster setup
provider: $PROVIDER_NAME
cluster_name: ${CLUSTER_NAME}
config_cluster_region: ${CLUSTER_REGION}

cluster_profile: ${OKD_INSTALLER_CLUSTER_PROFILE:-ha}
# destroy bootstrap isn't supported for oci (need to run destroy_all)
destroy_bootstrap: ${OKD_INSTALLER_DESTROY_BOOTSTRAP:-no}

config_base_domain: $OPCT_DOMAIN
config_ssh_key: "$(cat ${SSH_KEY_PATH})"
config_pull_secret_file: "/var/run/ci-credentials/registry/.dockerconfigjson"

config_cluster_version: $CLUSTER_VERSION
version: $CLUSTER_VERSION

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

# OCI supports only platform=external
if [[ "$PROVIDER_NAME" == "oci" ]]; then

  # Load Compartment IDs from secret
  source /var/run/vault/opct-splat/opct-runner-vars-compartments

  cat >> "${VARS_FILE}" << EOF
# provider specific: $PROVIDER_NAME
oci_compartment_id: ${OCI_COMPARTMENT_ID}
oci_compartment_id_dns: ${OCI_COMPARTMENT_ID_DNS}
oci_compartment_id_image: ${OCI_COMPARTMENT_ID_IMAGE}

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
EOF

fi

cp -vf "${VARS_FILE}" "${ARTIFACT_DIR}"/