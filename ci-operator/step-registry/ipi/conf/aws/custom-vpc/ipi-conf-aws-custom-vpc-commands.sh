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
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
  source_region=$(jq -r ".\"${REGION}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  REGION=$source_region
fi

az_file="${SHARED_DIR}/availability_zones"
pub_subnets_file="${SHARED_DIR}/public_subnet_ids"
priv_subnets_file="${SHARED_DIR}/private_subnet_ids"

if [ ! -f "${pub_subnets_file}" ] || [ ! -f "${priv_subnets_file}" ] || [ ! -f "${az_file}" ]; then
  echo "File ${pub_subnets_file} or ${priv_subnets_file} or ${az_file} does not exist."
  exit 1
fi

echo -e "public subnets: $(cat ${pub_subnets_file})"
echo -e "private subnets: $(cat ${priv_subnets_file})"
echo -e "AZs: $(cat ${az_file})"


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
  # generally, zones is not necessary for byo-subnets,
  # but if it’s required, we need to remove zone configurations added by ipi-conf-aws step to avoid conflicts
  yq-v4 -i 'del(.controlPlane.platform.aws.zones)' $CONFIG
  yq-v4 -i 'del(.compute[0].platform.aws.zones)' $CONFIG
  patch_az $CONFIG $(yq-v4 e -o=json '.' "${az_file}" | jq -r '.|join(" ")')
fi

if ((ocp_major_version == 4 && ocp_minor_version <= 18)); then
  if private_cluster; then
    echo "This is a private cluster so use only private subnets from the VPC"
    patch_legcy_subnets "${CONFIG}" $(yq-v4 e -o=json '.' "${priv_subnets_file}" | jq -r '.|join(" ")')

  else
    patch_legcy_subnets "${CONFIG}" $(yq-v4 e -o=json '.' "${priv_subnets_file}" | jq -r '.|join(" ")')
    patch_legcy_subnets "${CONFIG}" $(yq-v4 e -o=json '.' "${pub_subnets_file}" | jq -r '.|join(" ")')
  fi
else
  # for 4.19+
  if [[ ${ASSIGN_ROLES_TO_SUBNETS} == "yes" ]]; then

    if [[ ${SUBNET_ROLES} == "" ]]; then
      echo "ASSIGN_ROLES_TO_SUBNETS is set, but SUBNET_ROLES is empty, exit now."
    fi
    echo "SUBNET_ROLES:"
    echo ${SUBNET_ROLES}

    role_file=${ARTIFACT_DIR}/subnet_roles_file
    echo ${SUBNET_ROLES} | jq . > ${role_file}

    vpc_info_json=${SHARED_DIR}/vpc_info.json
    az_zone_count=$(jq -r '[.subnets[].az] | length' ${vpc_info_json})

    az_zone_count_in_role_file=$(jq -r '. | length' ${role_file})
    if [[ "${az_zone_count}" != "${az_zone_count_in_role_file}" ]]; then
      echo "ERROR: VPC and SUBNET_ROLES configurations are mismatch: the AZ count must be the same."
      echo "AZ count in SUBNET_ROLES: ${az_zone_count_in_role_file}"
      exit 1
    fi

    for az_idx in $(seq 0 $((az_zone_count-1)));
    do
      subnets_in_az_count=$(jq --argjson az_idx $az_idx '.subnets[$az_idx].ids | length' ${vpc_info_json})

      subnets_role_in_az_count=$(jq --argjson az_idx $az_idx '.[$az_idx] | length' ${role_file})
      if [[ "${subnets_in_az_count}" != "${subnets_role_in_az_count}" ]]; then
        echo "ERROR: VPC and SUBNET_ROLES configurations are mismatch: the subnets count in the same AZ must be the same."
        exit 1
      fi

      
      for subnet_idx in $(seq 0 $((subnets_in_az_count-1)));
      do

        public_subnet="$(jq -r --argjson az_idx $az_idx --argjson subnet_idx ${subnet_idx} '.subnets[$az_idx].ids[$subnet_idx] | .public' ${vpc_info_json})"
        public_roles="$(jq -r --argjson az_idx $az_idx --argjson subnet_idx ${subnet_idx} '.[$az_idx][$subnet_idx] | .public' "${role_file}")"

        private_subnet="$(jq -r --argjson az_idx $az_idx --argjson subnet_idx ${subnet_idx} '.subnets[$az_idx].ids[$subnet_idx] | .private' ${vpc_info_json})"
        private_roles="$(jq -r --argjson az_idx $az_idx --argjson subnet_idx ${subnet_idx} '.[$az_idx][$subnet_idx] | .private' "${role_file}")"

        if public_only; then
          patch_new_subnet_with_roles ${CONFIG} ${public_subnet} ${public_roles}
        elif private_cluster; then
          patch_new_subnet_with_roles ${CONFIG} ${private_subnet} ${private_roles}
        else
          patch_new_subnet_with_roles ${CONFIG} ${public_subnet} ${public_roles}
          patch_new_subnet_with_roles ${CONFIG} ${private_subnet} ${private_roles}
        fi
      done
    done
  else
    # no subnet roles
    unused_subnet_ids=""
    if public_only; then
      echo "This is a public-only cluster so use only public subnets from the VPC"
      patch_new_subnets "${CONFIG}" $(yq-v4 e -o=json '.' "${pub_subnets_file}" | jq -r '.|join(" ")')
      unused_subnet_ids=$(yq-v4 e -o=json '.' "${priv_subnets_file}" | jq -r '.|join(" ")')
    elif private_cluster; then
      echo "This is a private cluster so use only private subnets from the VPC"
      patch_new_subnets "${CONFIG}" $(yq-v4 e -o=json '.' "${priv_subnets_file}" | jq -r '.|join(" ")')
      unused_subnet_ids=$(yq-v4 e -o=json '.' "${pub_subnets_file}" | jq -r '.|join(" ")')
    else
      patch_new_subnets "${CONFIG}" $(yq-v4 e -o=json '.' "${priv_subnets_file}" | jq -r '.|join(" ")')
      patch_new_subnets "${CONFIG}" $(yq-v4 e -o=json '.' "${pub_subnets_file}" | jq -r '.|join(" ")')
    fi

    if [[ "${unused_subnet_ids}" != "" ]]; then
      # starting from 4.19, installer supports 
      #  AWS - Allocate Load Balancers (API & Ingress) to Specific Subnets https://issues.redhat.com/browse/OCPSTRAT-569
      #  A new restriction is introduced:
      #    Do Not Use Untagged Subnets User Stories
      #    https://github.com/openshift/enhancements/pull/1634/files#diff-ffcfdf0d21ba360a17e0ac9846e83eec8ecf0ba8b15d429d42e7de2dbd0bfaf7R151
      #  For private cluster, only private subnets were used, 
      #  to relieve CCM subnet discovery limitation, the other subnets in the same VPC (public subnets) require tag `kubernetes.io/cluster/unmanaged`
      echo "Attaching tag kubernetes.io/cluster/unmanaged to unused subnets in the same VPC, ${unused_subnet_ids}"
      aws --region $REGION ec2 create-tags --resources $unused_subnet_ids --tags Key=kubernetes.io/cluster/unmanaged,Value=true
    fi

  fi
fi

echo "install config:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform, "publish": .publish})' ${CONFIG} || true

set +x