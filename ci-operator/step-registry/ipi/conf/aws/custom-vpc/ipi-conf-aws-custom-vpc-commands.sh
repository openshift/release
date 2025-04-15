#!/bin/bash
# shellcheck disable=SC2046

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
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

CONFIG="${SHARED_DIR}/install-config.yaml"
REGION="${LEASED_RESOURCE}"

az_file="${SHARED_DIR}/availability_zones"
additional_az_file="${SHARED_DIR}/additional_availability_zones"

pub_subnets_file="${SHARED_DIR}/private_subnet_ids"
priv_subnets_file="${SHARED_DIR}/public_subnet_ids"
pub_additional_file="${SHARED_DIR}/public_additional_ids"
priv_additional_file="${SHARED_DIR}/private_additional_ids"

function additional_subnets()
{
  if [ -f ${pub_additional_file} ]; then
    return 0
  fi
  return 1
}

if [ ! -f "${pub_subnets_file}" ] || [ ! -f "${priv_subnets_file}" ] || [ ! -f "${az_file}" ]; then
  echo "File ${pub_subnets_file} or ${priv_subnets_file} or ${az_file} does not exist."
  exit 1
fi

ZONE_COUNT=$(cat "${az_file}" | jq '.|length')
ZONE_ADDITIONAL_COUNT=$(cat "${additional_az_file}" | jq '.|length')

echo -e "public subnets: $(cat ${pub_subnets_file})"
echo -e "private subnets: $(cat ${priv_subnets_file})"
echo -e "AZs: $(cat ${az_file})"

if additional_subnets; then
  echo -e "additional public subnets: $(cat ${pub_additional_file})"
  echo -e "additional private subnets: $(cat ${priv_additional_file})"
  echo -e "additional AZs: $(cat ${additional_az_file})"
fi


function public_only()
{  
  if [[ "${OPENSHIFT_INSTALL_AWS_PUBLIC_ONLY:-}" != "" ]]; then
    return 0
  else
    return 1
  fi
}

function private_cluster()
{  
  if [ -n "${PUBLISH}" ] && [ X"${PUBLISH}" == X"Internal" ]; then
    return 0
  else
    return 1
  fi
}

function patch_az()
{
    local config=$1
    shift
    azs=$(echo "$@" | yq-v4 -o yaml 'split(" ") | map(.)')
    export azs
    yq-v4 eval -i '.compute[0].platform.aws.zones += env(azs)' ${config}
    yq-v4 eval -i '.controlPlane.platform.aws.zones += env(azs)' ${config}
    unset azs
}

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
    if [[ "$*" == "" ]]; then
	    return 0
    fi
    roles=$(echo "$@" | yq-v4 -o yaml 'split(" ") | map({"type": .})')
    export subnet roles
    yq-v4 eval -i '.platform.aws.vpc.subnets += [{"id": env(subnet), "roles": env(roles)}]' ${config}
    unset subnet roles
}

if [[ ${ADD_ZONES} == "yes" ]]; then
  patch_az $CONFIG $(jq -r '.|join(" ")' "${az_file}")
fi

if ((ocp_major_version == 4 && ocp_minor_version <= 18)); then
  if private_cluster; then
    echo "This is a private cluster so use only private subnets from the VPC"
    patch_legcy_subnets "${CONFIG}" $(jq -r '.|join(" ")' "${priv_subnets_file}")
  else
    patch_legcy_subnets "${CONFIG}" $(jq -r '.|join(" ")' "${priv_subnets_file}")
    patch_legcy_subnets "${CONFIG}" $(jq -r '.|join(" ")' "${pub_subnets_file}")
  fi
else
  # for 4.19+
  if [[ ${ASSIGN_ROLES_TO_SUBNETS} == "yes" ]]; then

    if [[ ${SUBNET_ROLES} == "" ]]; then
      echo "ASSIGN_ROLES_TO_SUBNETS is set, but SUBNET_ROLES is empty, exit now."
    fi
    echo "SUBNET_ROLES:"
    echo ${SUBNET_ROLES}

    role_file=/tmp/subnet_roles_file
    echo ${SUBNET_ROLES} | jq . > ${role_file}

    for idx in $(seq 0 $((ZONE_COUNT-1)));
    do
      if public_only; then
        patch_new_subnet_with_roles ${CONFIG} $(jq -r --argjson i ${idx} '.[$i]' "${pub_subnets_file}") $(jq -r --argjson i ${idx} '.[$i][0] | .pub' "${role_file}")
      elif private_cluster; then
        patch_new_subnet_with_roles ${CONFIG} $(jq -r --argjson i ${idx} '.[$i]' "${priv_subnets_file}") $(jq -r --argjson i ${idx} '.[$i][0] | .priv' "${role_file}")
      else
        patch_new_subnet_with_roles ${CONFIG} $(jq -r --argjson i ${idx} '.[$i]' "${pub_subnets_file}") $(jq -r --argjson i ${idx} '.[$i][0] | .pub' "${role_file}")
        patch_new_subnet_with_roles ${CONFIG} $(jq -r --argjson i ${idx} '.[$i]' "${priv_subnets_file}") $(jq -r --argjson i ${idx} '.[$i][0] | .priv' "${role_file}")
      fi
    done

    if additional_subnets; then
      for idx in $(seq 0 $((ZONE_ADDITIONAL_COUNT-1)));
      do
        if public_only; then
          patch_new_subnet_with_roles ${CONFIG} $(jq -r --argjson i ${idx} '.[$i]' "${pub_additional_file}") $(jq -r --argjson i ${idx} '.[$i][1] | .pub' "${role_file}")
        elif private_cluster; then
          patch_new_subnet_with_roles ${CONFIG} $(jq -r --argjson i ${idx} '.[$i]' "${priv_additional_file}") $(jq -r --argjson i ${idx} '.[$i][1] | .priv' "${role_file}")
        else
          patch_new_subnet_with_roles ${CONFIG} $(jq -r --argjson i ${idx} '.[$i]' "${pub_additional_file}") $(jq -r --argjson i ${idx} '.[$i][1] | .pub' "${role_file}")
          patch_new_subnet_with_roles ${CONFIG} $(jq -r --argjson i ${idx} '.[$i]' "${priv_additional_file}") $(jq -r --argjson i ${idx} '.[$i][1] | .priv' "${role_file}")
        fi
      done
    fi


  else
    # no subnet roles 
    if private_cluster; then
      echo "This is a private cluster so use only private subnets from the VPC"
      patch_new_subnets "${CONFIG}" $(jq -r '.|join(" ")' "${priv_subnets_file}")

      # starting from 4.19, installer supports 
      #  AWS - Allocate Load Balancers (API & Ingress) to Specific Subnets https://issues.redhat.com/browse/OCPSTRAT-569
      #  A new restriction is introduced:
      #    Do Not Use Untagged Subnets User Stories
      #    https://github.com/openshift/enhancements/pull/1634/files#diff-ffcfdf0d21ba360a17e0ac9846e83eec8ecf0ba8b15d429d42e7de2dbd0bfaf7R151
      #  For private cluster, only private subnets were used, 
      #  to relieve CCM subnet discovery limitation, the other subnets in the same VPC (public subnets) require tag `kubernetes.io/cluster/unmanaged`
      unused_subnet_ids=$(jq -r '.|join(" ")' "${pub_subnets_file}")
      echo "Attaching tag kubernetes.io/cluster/unmanaged to unused subnets in the same VPC, ${unused_subnet_ids}"
      aws --region $REGION ec2 create-tags --resources $unused_subnet_ids --tags Key=kubernetes.io/cluster/unmanaged,Value=true
    else
      patch_new_subnets "${CONFIG}" $(jq -r '.|join(" ")' "${priv_subnets_file}")
      patch_new_subnets "${CONFIG}" $(jq -r '.|join(" ")' "${pub_subnets_file}")
    fi
  fi
fi

echo "install config:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform, "publish": .publish})' ${CONFIG} || true

set +x