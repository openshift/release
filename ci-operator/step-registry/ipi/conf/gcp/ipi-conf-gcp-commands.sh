#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
GCP_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GCP_REGION="${LEASED_RESOURCE}"

masters="${CONTROL_PLANE_REPLICAS}"

workers=3
if [[ "${SIZE_VARIANT}" == "compact" ]]; then
  workers=0
fi

# Do not change the default family type without consulting with cloud financial operations as their may
# be active savings plans targeting this machine class.
master_type=""
# Temporary test to see if this helps the consistent high CPU alerts and random test failures
master_type_suffix="-custom-6-16384"
#master_type_suffix="-standard-4"
if [[ "${SIZE_VARIANT}" == "xlarge" ]]; then
  master_type_suffix="-standard-32"
elif [[ "${SIZE_VARIANT}" == "large" ]]; then
  master_type_suffix="-standard-16"
elif [[ "${SIZE_VARIANT}" == "compact" ]]; then
  master_type_suffix="-standard-8"
fi
if [ "${OCP_ARCH}" = "amd64" ]; then
  master_type="e2${master_type_suffix}"
elif [ "${OCP_ARCH}" = "arm64" ]; then
  # TODO: revert back to master_type_suffix if/when we switch back to standard
  # custom sizes are not supported by arm64 VMs
  master_type="t2a-standard-4"
fi

cat >> "${CONFIG}" << EOF
baseDomain: ${GCP_BASE_DOMAIN}
platform:
  gcp:
    projectID: ${GCP_PROJECT}
    region: ${GCP_REGION}
controlPlane:
  architecture: ${OCP_ARCH}
  name: master
  platform:
    gcp:
      type: ${master_type}
      osDisk:
        diskType: pd-ssd
        diskSizeGB: 200
  replicas: ${masters}
compute:
- architecture: ${OCP_ARCH}
  name: worker
  replicas: ${workers}
  platform:
    gcp:
      type: ${COMPUTE_NODE_TYPE}
EOF

if [ ${RT_ENABLED} = "true" ]; then
	cat > "${SHARED_DIR}/manifest_mc-kernel-rt.yml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: realtime-worker
spec:
  kernelType: realtime
EOF
fi

if [[ -s "${SHARED_DIR}/customer_vpc_subnets.yaml" ]]; then
  yq-go m -x -i "${CONFIG}" "${SHARED_DIR}/customer_vpc_subnets.yaml"
fi

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
rm /tmp/pull-secret

if (( ocp_minor_version > 10 || ocp_major_version > 4 )); then
  SERVICE="quayio-pull-through-cache-gcs-ci.apps.ci.l2s4.p1.openshiftapps.com"
  PATCH="${SHARED_DIR}/install-config-image-content-sources.yaml.patch"
  cat > "${PATCH}" << EOF
imageContentSources:
- mirrors:
  - ${SERVICE}
  source: quay.io
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"

  pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
  mirror_auth=$(echo ${pull_secret} | jq '.auths["quay.io"].auth' -r)
  pull_secret_gcp=$(jq --arg auth ${mirror_auth} --arg repo "${SERVICE}" '.["auths"] += {($repo): {$auth}}' <<<  $pull_secret)

  PATCH="/tmp/install-config-pull-secret-gcp.yaml.patch"
  cat > "${PATCH}" << EOF
pullSecret: >
  $(echo "${pull_secret_gcp}" | jq -c .)
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  rm "${PATCH}"
fi
