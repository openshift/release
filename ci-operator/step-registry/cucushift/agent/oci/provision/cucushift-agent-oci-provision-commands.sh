#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

source "${SHARED_DIR}"/platform-conf.sh
CONTENT=$(<"${CLUSTER_PROFILE_DIR}"/oci-privatekey)
export OCI_CLI_KEY_CONTENT=${CONTENT}
NAMESPACE_NAME=$(<"${CLUSTER_PROFILE_DIR}"/namespace-name)
BUCKET_NAME=$(<"${CLUSTER_PROFILE_DIR}"/bucket-name)
echo "export NAMESPACE_NAME=${NAMESPACE_NAME}; export BUCKET_NAME=${BUCKET_NAME}" >> "${SHARED_DIR}"/platform-conf.sh
CLUSTER_NAME=$(<"${SHARED_DIR}"/cluster-name.txt)
BASE_DOMAIN=$(<"${SHARED_DIR}"/base-domain.txt)

machineNetwork=$( [ "${ISCSI:-false}" == "true" ] && echo "10.0.32.0/20" || echo "10.0.16.0/20" )

yq --inplace eval-all 'select(fileIndex == 0) * select(fileIndex == 1)' "$SHARED_DIR/install-config.yaml" - <<<"
baseDomain: ${BASE_DOMAIN}
controlPlane:
  name: master
  replicas: ${MASTERS}
compute:
- name: worker
  replicas: ${WORKERS}
networking:
  machineNetwork:
  - cidr: ${machineNetwork}
platform:
  external:
    cloudControllerManager: External
    platformName: oci
"

pull_secret_path=${CLUSTER_PROFILE_DIR}/pull-secret
build03_secrets="/var/run/vault/secrets/.dockerconfigjson"
extract_build03_auth=$(jq -c '.auths."registry.build03.ci.openshift.org"' ${build03_secrets})
final_pull_secret=$(jq -c --argjson auth "$extract_build03_auth" '.auths["registry.build03.ci.openshift.org"] += $auth' "${pull_secret_path}")

echo "${final_pull_secret}" >>"${SHARED_DIR}"/pull-secrets
pull_secret=$(<"${SHARED_DIR}/pull-secrets")

# Add build03 secrets if the mirror registry secrets are not available.
if [ ! -f "${SHARED_DIR}/pull_secret_ca.yaml.patch" ]; then
  yq -i 'del(.pullSecret)' "${SHARED_DIR}/install-config.yaml"
  cat >>"${SHARED_DIR}/install-config.yaml" <<EOF
pullSecret: >
  ${pull_secret}
EOF
fi
echo "Creating agent image..."
INSTALL_DIR=/tmp/installer
mkdir -p "${INSTALL_DIR}"/openshift
pushd ${INSTALL_DIR}
cp -t "${INSTALL_DIR}" "${SHARED_DIR}"/{install-config.yaml,agent-config.yaml}

echo "Installing from initial release $OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"
oc adm release extract -a "${SHARED_DIR}"/pull-secrets "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" \
  --command=openshift-install --to=/tmp

echo "Copying Custom Manifest"
oci resource-manager job-output-summary list-job-outputs \
--job-id "${JOB_ID}" \
--query "data.items[?\"output-name\"=='dynamic_custom_manifest'].\"output-value\" | [0]" \
--raw-output > "${INSTALL_DIR}"/openshift/custom-manifest.yaml

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

grep -v "password\|username\|pullSecret" "${SHARED_DIR}/install-config.yaml" > "${ARTIFACT_DIR}/install-config.yaml" || true
grep -v "password\|username\|pullSecret" "${SHARED_DIR}/agent-config.yaml" > "${ARTIFACT_DIR}/agent-config.yaml" || true

/tmp/openshift-install agent create image --dir="${INSTALL_DIR}" --log-level debug

echo "Copying kubeconfig to the shared directory..."
cp -t "${SHARED_DIR}" \
  "${INSTALL_DIR}/auth/kubeadmin-password" \
  "${INSTALL_DIR}/auth/kubeconfig"

AGENT_IMAGE="agent.x86_64_${CLUSTER_NAME}.iso"
mv "${INSTALL_DIR}"/agent.x86_64.iso "${INSTALL_DIR}"/"${AGENT_IMAGE}"
echo "${AGENT_IMAGE}" > "${SHARED_DIR}"/agent-image.txt

oci os object put -bn "${BUCKET_NAME}" --file "${INSTALL_DIR}"/"${AGENT_IMAGE}" -ns "${NAMESPACE_NAME}"

EXPIRE_DATE=$(date -d "+7 days" +"%Y-%m-%d")

echo "Creating Pre-auth Request"
IMAGE_URI=$(oci os preauth-request create \
-bn "${BUCKET_NAME}" \
-ns "${NAMESPACE_NAME}" \
--access-type ObjectRead \
--object-name "${AGENT_IMAGE}" \
--name "${CLUSTER_NAME}" \
--time-expires "${EXPIRE_DATE}" \
--query 'data."full-path"' --raw-output)

VARIABLES=$(cat <<EOF
{"openshift_image_source_uri":"${IMAGE_URI}",
"zone_dns":"${BASE_DOMAIN}",
"installation_method":"Agent-based",
"control_plane_count":"${MASTERS}",
"compute_count":"${WORKERS}",
"cluster_name":"${CLUSTER_NAME}",
"tenancy_ocid":"${OCI_CLI_TENANCY}",
"create_openshift_instances":true,
"compartment_ocid":"${COMPARTMENT_ID}",
"region":"${OCI_CLI_REGION}"}
EOF
)

if [ "${ISCSI:-false}" = "true" ]; then
    VARIABLES=$(echo "${VARIABLES}" | jq '. + {control_plane_shape:"BM.Standard2.52",compute_shape:"BM.Standard3.64",rendezvous_ip:"10.0.32.20"}')
fi

echo "Updating Stack Variables"
oci resource-manager stack update \
--stack-id "${STACK_ID}" \
--variables "${VARIABLES}" \
--query 'data.id' --raw-output \
--force

echo "Creating Apply Job"
oci resource-manager job create-apply-job \
--stack-id "${STACK_ID}" \
--execution-plan-strategy AUTO_APPROVED \
--max-wait-seconds 2400 \
--wait-for-state SUCCEEDED \
--query 'data."lifecycle-state"'

## Monitor for `bootstrap-complete`
echo "$(date -u --rfc-3339=seconds) - Monitoring for bootstrap to complete"
/tmp/openshift-install --dir="${INSTALL_DIR}" agent wait-for bootstrap-complete &

if ! wait $!; then
  echo "ERROR: Bootstrap failed. Aborting execution."
  exit 1
fi

## Monitor for cluster completion
echo "$(date -u --rfc-3339=seconds) - Monitoring for cluster completion..."

# When using line-buffering there is a potential issue that the buffer is not filled (or no new line) and this waits forever
# or in our case until the four hour CI timer is up.
/tmp/openshift-install --dir="${INSTALL_DIR}" agent wait-for install-complete --log-level=debug 2>&1 | stdbuf -o0 grep -v password &

if ! wait "$!"; then
  echo "ERROR: Installation failed. Aborting execution."
  exit 1
fi

echo "Ensure that all the cluster operators remain stable and ready until OCPBUGS-18658 is fixed."
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=60m