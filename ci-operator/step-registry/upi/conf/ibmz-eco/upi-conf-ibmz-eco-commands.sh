#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi
if [[ -z "${OPENSTACK_COMPUTE_FLAVOR}" ]]; then
  echo "Compute flavor isn't specified. Using 'medium' by default."
  export OPENSTACK_COMPUTE_FLAVOR="medium"
fi
if [[ -z "${OS_CLOUD}" ]]; then
  echo "OpenStack cloud isn't specified. Using 'openstack' by default."
  export OS_CLOUD="rhcert"
fi
if [[ -z "${CLUSTER_DOMAIN}" ]]; then
  echo "Cluster's base domain must be specified in CLUSTER_DOMAIN."
  exit 1
fi
if [[ -z "${OS_VERSION}" ]]; then
  echo "OpenShift target version isn't specified. Using '4.6' by default."
  export OS_VERSION="4.6"
fi

export HOME=/tmp

pull_secret_in=/etc/pull-secret/.dockerconfigjson
pull_secret_out=${SHARED_DIR}/pull-secret
tfvars_out=${SHARED_DIR}/terraform.tfvars
ocp_version=${RELEASE_IMAGE_LATEST}
echo "${NAMESPACE}-${JOB_NAME_HASH}" > "${SHARED_DIR}"/clustername.txt
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)
echo "Configuring deployment of OpenShift ${OS_VERSION} under the name ${cluster_name}"

export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}
# Ensure ignition assets are configured with the correct invoker to track CI jobs.
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}

# Retrieve pull-secret
echo "$(date -u --rfc-3339=seconds) - Retrieving pull-secret..."
cp ${pull_secret_in} ${pull_secret_out}
# Create terraform.tfvars
echo "$(date -u --rfc-3339=seconds) - Creating terraform variables file..."
cat > "${tfvars_out}" <<-EOF
cluster_id = "${cluster_name}"
cloud_domain = "${CLUSTER_DOMAIN}"
openshift_version = "${OS_VERSION}"
image_override = "${RELEASE_IMAGE_LATEST}"
worker_count = "2"
openstack_master_flavor_name = "large"
openstack_worker_flavor_name = "${OPENSTACK_COMPUTE_FLAVOR}"
openstack_bastion_flavor_name = "medium"
openstack_credentials_cloud = "${OS_CLOUD}"
openshift_pull_secret_filepath = "./ocp_clusters/${cluster_name}/pull-secret"
EOF