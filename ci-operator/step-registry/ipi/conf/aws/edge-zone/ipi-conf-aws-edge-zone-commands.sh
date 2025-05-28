#!/bin/bash
# shellcheck disable=SC2046

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_INITIAL:-}"
if [[ -z "${RELEASE_IMAGE_INSTALL}" ]]; then
  # If there is no initial release, we will be installing latest.
  RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_LATEST:-}"
fi
cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_INSTALL} -ojsonpath='{.metadata.version}' | cut -d. -f 1,2)
ocp_major_version=$(echo "${ocp_version}" | awk --field-separator=. '{print $1}')
ocp_minor_version=$(echo "${ocp_version}" | awk --field-separator=. '{print $2}')
rm /tmp/pull-secret

set -x

function patch_legcy_subnets()
{
    local config=$1
    shift
    for subnet in "$@"; do
        export subnet
        yq-v4 eval -i '.platform.aws.subnets += [env(subnet)]' ${config}
        unset subnet
    done
}

function patch_new_subnets()
{
    local config=$1
    shift
    for subnet in "$@"; do
        export subnet
        yq-v4 eval -i '.platform.aws.vpc.subnets += [{"id": env(subnet)}]' ${config}
        unset subnet
    done
}

function patch_new_subnet_with_roles()
{
    local config=$1
    local subnet=$2
    shift 2
    roles=$(echo "$@" | yq-v4 -o yaml 'split(" ") | map({"type": .})')
    export subnet roles
    yq-v4 eval -i '.platform.aws.vpc.subnets += [{"id": env(subnet), "roles": env(roles)}]' ${config}
    unset subnet roles
}

edge_zones=""
while IFS= read -r line; do
  if [[ -z "${edge_zones}" ]]; then
    edge_zones="$line";
  else
    edge_zones+=",$line";
  fi
done < <(grep -v '^$' < "${SHARED_DIR}"/edge-zone-names.txt)

edge_zones_str="[ $edge_zones ]"
echo "Selected Local Zone: ${edge_zones_str}"

PATCH="${ARTIFACT_DIR}/install-config-edge-zone.yaml.patch"
cat <<EOF > "${PATCH}"
compute:
- name: edge
  architecture: amd64
  hyperthreading: Enabled
  replicas: ${EDGE_NODE_WORKER_NUMBER}
  platform:
    aws:
      zones: ${edge_zones_str}
EOF

yq-v4 eval-all -i 'select(fileIndex == 0) *+ select(fileIndex == 1)' ${CONFIG} ${PATCH}

if [[ ${EDGE_NODE_INSTANCE_TYPE} != "" ]]; then
  echo "EDGE_NODE_INSTANCE_TYPE: ${EDGE_NODE_INSTANCE_TYPE}"
  echo "      type: ${EDGE_NODE_INSTANCE_TYPE}" >> ${PATCH}
else
  echo "EDGE_NODE_INSTANCE_TYPE: Empty, will be determined by installer"
fi

if [[ -e "${SHARED_DIR}/edge_zone_subnet_id" ]]; then
  edge_zone_subnet_id=$(head -n 1 "${SHARED_DIR}/edge_zone_subnet_id")
  if ((ocp_major_version == 4 && ocp_minor_version <= 18)); then
    patch_legcy_subnets ${CONFIG} ${edge_zone_subnet_id}
  else
    if [[ ${ASSIGN_ROLES_TO_SUBNETS} == "yes" ]]; then
      patch_new_subnet_with_roles ${CONFIG} ${edge_zone_subnet_id} "EdgeNode"
    else
      patch_new_subnets ${CONFIG} ${edge_zone_subnet_id}
    fi
  fi
fi

echo "install config:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform, "publish": .publish})' ${CONFIG} || true

set +x