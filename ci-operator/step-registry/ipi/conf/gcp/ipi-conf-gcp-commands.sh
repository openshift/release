#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

GCP_BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
if [[ -n "${BASE_DOMAIN}" ]]; then
  GCP_BASE_DOMAIN="${BASE_DOMAIN}"
fi
GCP_PROJECT="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
GCP_REGION="${LEASED_RESOURCE}"

masters="${CONTROL_PLANE_REPLICAS}"

workers=${COMPUTE_NODE_REPLICAS:-3}
if [ "${COMPUTE_NODE_REPLICAS}" -le 0 ] || [ "${SIZE_VARIANT}" = "compact" ]; then
  workers=0
fi

# Do not change the default family type without consulting with cloud financial operations as their may
# be active savings plans targeting this machine class.
master_type=""
control_plane_arch="${CONTROL_ARCH:-${OCP_ARCH}}"
case "${SIZE_VARIANT}" in
  "xlarge")
    master_type_suffix="standard-32"
  ;;
  "large")
    master_type_suffix="standard-16"
  ;;
  "compact")
    master_type_suffix="standard-8"
  ;;
  *)
    if [[ "${control_plane_arch}" == "arm64" ]]; then
      master_type_suffix="standard-4"
    else
      # Temporary test to see if this helps the consistent high CPU alerts and random test failures
      master_type_suffix="custom-6-16384"
      # TODO: remove if block and revert master_type_suffix back to standard if/when we switch back to standard
      # custom sizes are not supported by arm64 VMs
    fi
  ;;
esac

if [[ "${control_plane_arch}" == "amd64" ]]; then
  master_type="e2-${master_type_suffix}"
elif [[ "${control_plane_arch}" == "arm64" ]]; then
  master_type="t2a-${master_type_suffix}"
fi

compute_arch="${COMPUTE_ARCH:-${OCP_ARCH}}"
if [[ -z "${COMPUTE_NODE_TYPE}" ]]; then
  if [[ "${compute_arch}" == "arm64" ]]; then
    COMPUTE_NODE_TYPE="t2a-standard-4"
  else
    COMPUTE_NODE_TYPE="e2-custom-6-16384"
  fi
fi

# Get standard zones from the region (excluding AI zones) and randomize selection
# This prevents control plane nodes from being placed in AI zones when zones aren't explicitly set
function get_zones_from_region() {
  local zone_count=${1:-3}
  # Get all zones from the region, filtering out AI zones and randomizing
  mapfile -t AVAILABILITY_ZONES < <(gcloud compute zones list --filter="region:${GCP_REGION} AND status:UP" --format='value(name)' 2>/dev/null | grep -v '\-ai[0-9]' | shuf)
  
  # Take the first zone_count zones
  local zones=("${AVAILABILITY_ZONES[@]:0:${zone_count}}")
  # Format as YAML array: [zone1, zone2, zone3]
  local zones_str="["
  for i in "${!zones[@]}"; do
    if [[ $i -gt 0 ]]; then
      zones_str+=", "
    fi
    zones_str+="${zones[$i]}"
  done
  zones_str+="]"
  echo "${zones_str}"
}

cat >> "${CONFIG}" << EOF
baseDomain: ${GCP_BASE_DOMAIN}
platform:
  gcp:
    projectID: ${GCP_PROJECT}
    region: ${GCP_REGION}
controlPlane:
  architecture: ${control_plane_arch}
  name: master
  platform:
    gcp:
      type: ${master_type}
      osDisk:
        diskType: pd-ssd
        diskSizeGB: 200
  replicas: ${masters}
compute:
- architecture: ${compute_arch}
  name: worker
  replicas: ${workers}
  platform:
    gcp:
      type: ${COMPUTE_NODE_TYPE}
EOF

# Set zones for control plane and compute in regions with AI zones to avoid AI zones
# AI zones (e.g., us-central1-ai1a, us-south1-ai1b) are optimized for GPU/AI machine types
# and should not be used for standard machine types like control plane nodes
if [[ "${GCP_REGION}" == "us-central1" ]] || [[ "${GCP_REGION}" == "us-south1" ]]; then
  export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
  GOOGLE_PROJECT_ID=$(jq -r .project_id ${GCP_SHARED_CREDENTIALS_FILE} 2>/dev/null || echo "")
  if [[ -n "${GOOGLE_PROJECT_ID}" ]]; then
    sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE} 2>/dev/null || echo "")
    if [[ -n "${sa_email}" ]] && ! gcloud auth list 2>/dev/null | grep -qE "\*\s+${sa_email}"; then
      gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}" 2>/dev/null || true
      gcloud config set project "${GOOGLE_PROJECT_ID}" 2>/dev/null || true
    fi
    
    # Get zones for control plane (3 zones for HA)
    CONTROL_PLANE_ZONES_STR=$(get_zones_from_region 3)
    # Get zones for compute (same zones for consistency)
    COMPUTE_ZONES_STR="${CONTROL_PLANE_ZONES_STR}"
    
    # Apply zones via patch if we got valid zones
    if [[ -n "${CONTROL_PLANE_ZONES_STR}" ]] && [[ "${CONTROL_PLANE_ZONES_STR}" != "[]" ]]; then
      PATCH="${SHARED_DIR}/install-config-zones.yaml.patch"
      cat > "${PATCH}" << ZONESPATCH
controlPlane:
  platform:
    gcp:
      zones: ${CONTROL_PLANE_ZONES_STR}
compute:
- platform:
    gcp:
      zones: ${COMPUTE_ZONES_STR}
ZONESPATCH
      yq-go m -x -i "${CONFIG}" "${PATCH}"
      rm "${PATCH}"
    fi
  fi
fi

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

# cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
# oc registry login --to /tmp/pull-secret
# ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
# ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
# ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
# rm /tmp/pull-secret

# if (( ocp_minor_version > 10 || ocp_major_version > 4 )); then
#   SERVICE="quayio-pull-through-cache-gcs-ci.apps.ci.l2s4.p1.openshiftapps.com"
#   PATCH="${SHARED_DIR}/install-config-image-content-sources.yaml.patch"
#   cat > "${PATCH}" << EOF
# imageContentSources:
# - mirrors:
#   - ${SERVICE}
#   source: quay.io
# EOF
#   yq-go m -x -i "${CONFIG}" "${PATCH}"

#   pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
#   mirror_auth=$(echo ${pull_secret} | jq '.auths["quay.io"].auth' -r)
#   pull_secret_gcp=$(jq --arg auth ${mirror_auth} --arg repo "${SERVICE}" '.["auths"] += {($repo): {$auth}}' <<<  $pull_secret)

#   PATCH="/tmp/install-config-pull-secret-gcp.yaml.patch"
#   cat > "${PATCH}" << EOF
# pullSecret: >
#   $(echo "${pull_secret_gcp}" | jq -c .)
# EOF
#   yq-go m -x -i "${CONFIG}" "${PATCH}"
#   rm "${PATCH}"
# fi

if [[ "${USER_PROVISIONED_DNS}" == "yes" ]]; then
  patch_user_provisioned_dns="${SHARED_DIR}/install-config-user-provisioned-dns.yaml.patch"
  cat > "${patch_user_provisioned_dns}" << EOF
platform:
  gcp:
    userProvisionedDNS: Enabled
EOF
  yq-go m -a -x -i "${CONFIG}" "${patch_user_provisioned_dns}"
fi
