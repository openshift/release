#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

CONFIG="${SHARED_DIR}/install-config.yaml"

expiration_date=$(date -d '8 hours' --iso=minutes --utc)

function join_by { local IFS="$1"; shift; echo "$*"; }


# REGION: the region that OCP will be installed
# aws_source_region: for non-C2S/SC2S cluster, it's the same as REGION, for C2S/SC2S it's the source region that emulator runs on.
#             e.g. for instance, if installing a cluster on a C2S (us-iso-east-1) region and its emulator runs on us-east-1:
#                  so the REGION is us-iso-east-1, and aws_source_region is us-east-1
REGION="${LEASED_RESOURCE}"
aws_source_region="${REGION}"

if [[ "${CLUSTER_TYPE}" =~ ^aws-s?c2s$ ]]; then
  # in C2S/SC2S use source_region (us-east-1) to communicate with AWS services
  aws_source_region=$(jq -r ".\"${REGION}\".source_region" "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
  echo "C2S/SC2S source region: $aws_source_region"
fi

function eval_instance_capacity() {
  local DESIRED_TYPE="$1"
  local FALLBACK_TYPE="$2"
  # During our initial adoption of m6a, AWS has report insufficient capacity at peak hours. For cost effectiveness
  # and to ensure AWS eventual adds m6a capacity due to these errors, we want to continue to use them. However,
  # if left unchecked, these peak hour errors can derail a statistically significant number of jobs.
  # To mitigate the capacity issues, search.ci.openshift.org can tell us if previous jobs have failed to provision
  # the desired instance type - in this region - in the last x minutes.
  # If we find such an error, use the fallback instance type.

  # Example error
  # error creating EC2 instance: InsufficientInstanceCapacity: We currently do not have sufficient m6a.xlarge capacity
  # in the Availability Zone you requested (us-east-1c). Our system will be working on provisioning additional capacity.
  # You can currently get m6a.xlarge capacity by not specifying an Availability Zone in your request or choosing
  # us-east-1a, us-east-1b, us-east-1d, us-east-1f.\n	status code: 500, request id: ...

  set +o errexit
  local LOOK_BACK_PERIOD="30m"
  local TARGET_TYPE="${DESIRED_TYPE}"
  for retry in {1..30}; do
    if err_count=$(curl -L -s "https://search.ci.openshift.org/search?search=InsufficientInstanceCapacity.*${DESIRED_TYPE}.*${REGION}&maxAge=${LOOK_BACK_PERIOD}&context=0&type=build-log" | jq length); then
      if [[ "${err_count}" == "0" ]]; then
        break  # Use DESIRED_TYPE
      else
        >&2 echo "Recent instance AWS availability issue for ${DESIRED_TYPE} in ${REGION}; falling back to ${FALLBACK_TYPE}"
        TARGET_TYPE="${FALLBACK_TYPE}"
        break
      fi
    fi
    sleep 2
    >&2 echo "Error querying search.ci.openshift.com for AWS instance availability information (retry ${retry} of 30)."
  done

  echo "${TARGET_TYPE}"
  set -o errexit
}


# BootstrapInstanceType gets its value from pkg/types/aws/defaults/platform.go
architecture=${OCP_ARCH:-"amd64"}

CONTROL_PLANE_INSTANCE_SIZE="xlarge"
if [[ "${SIZE_VARIANT}" == "xlarge" ]]; then
  CONTROL_PLANE_INSTANCE_SIZE="8xlarge"
elif [[ "${SIZE_VARIANT}" == "large" ]]; then
  CONTROL_PLANE_INSTANCE_SIZE="4xlarge"
elif [[ "${SIZE_VARIANT}" == "compact" ]]; then
  CONTROL_PLANE_INSTANCE_SIZE="2xlarge"
fi

if [[ "${CLUSTER_TYPE}" =~ ^aws-s?c2s$ ]]; then
  # C2S & SC2S

  # Not all instance family are supported by SHIFT emulator
  #   see https://bugzilla.redhat.com/show_bug.cgi?id=2020181

  if [[ "${COMPUTE_NODE_TYPE}" == "" ]]; then
    COMPUTE_NODE_TYPE="m5.xlarge"
  fi

  if [[ "${CONTROL_PLANE_INSTANCE_TYPE}" == "" ]]; then
    CONTROL_PLANE_INSTANCE_TYPE="m5.${CONTROL_PLANE_INSTANCE_SIZE}"
  fi
elif [[ "${CLUSTER_TYPE}" == "aws-arm64" ]] || [[ "${OCP_ARCH}" == "arm64" ]]; then
  # ARM 64
  architecture="arm64"
  if [[ "${COMPUTE_NODE_TYPE}" == "" ]]; then
    COMPUTE_NODE_TYPE="m6g.xlarge"
  fi

  if [[ "${CONTROL_PLANE_INSTANCE_TYPE}" == "" ]]; then
    CONTROL_PLANE_INSTANCE_TYPE="m6g.${CONTROL_PLANE_INSTANCE_SIZE}"
  fi
else
  # AMD 64

  # m6a (AMD) are more cost effective than other x86 instance types
  # for general purpose work. Use by default, when supported in the
  # region.
  IS_M6A_REGION="no"
  if aws ec2 describe-instance-type-offerings --region "${REGION}" | grep -q m6a ; then
    IS_M6A_REGION="yes"
  fi

  # Do not change auto-types unless it is coordinated with the cloud
  # financial operations team. Savings plans may be in place to
  # decrease the cost of certain instance families.
  if [[ "${CONTROL_PLANE_INSTANCE_TYPE}" == "" ]]; then
    if [[ "${IS_M6A_REGION}" == "yes" ]]; then
      CONTROL_PLANE_INSTANCE_TYPE=$(eval_instance_capacity "m6a.${CONTROL_PLANE_INSTANCE_SIZE}" "m6i.${CONTROL_PLANE_INSTANCE_SIZE}")
    else
      CONTROL_PLANE_INSTANCE_TYPE="m6i.${CONTROL_PLANE_INSTANCE_SIZE}"
    fi
  fi

  if [[ "${COMPUTE_NODE_TYPE}" == "" ]]; then
    if [[ "${IS_M6A_REGION}" == "yes" ]]; then
      COMPUTE_NODE_TYPE=$(eval_instance_capacity "m6a.xlarge" "m6i.xlarge")
    else
      COMPUTE_NODE_TYPE="m6i.xlarge"
    fi
  fi

fi

arch_instance_type=$(echo -n "${CONTROL_PLANE_INSTANCE_TYPE}" | cut -d . -f 1)
BOOTSTRAP_NODE_TYPE=${arch_instance_type}.large

worker_replicas=${COMPUTE_NODE_REPLICAS:-3}
if [[ "${COMPUTE_NODE_REPLICAS}" -le 0 ]]; then
    worker_replicas=0
fi

if [[ "${SIZE_VARIANT}" == "compact" ]]; then
  worker_replicas=0
fi

master_replicas=${CONTROL_PLANE_REPLICAS:-3}

# Generate working availability zones from the region
mapfile -t AVAILABILITY_ZONES < <(aws --region "${aws_source_region}" ec2 describe-availability-zones --filter Name=state,Values=available Name=zone-type,Values=availability-zone | jq -r '.AvailabilityZones[] | select(.State == "available") | .ZoneName' | sort -u)
# Generate availability zones with OpenShift Installer required instance types

if [[ "${COMPUTE_NODE_TYPE}" == "${BOOTSTRAP_NODE_TYPE}" && "${COMPUTE_NODE_TYPE}" == "${CONTROL_PLANE_INSTANCE_TYPE}" ]]; then ## all regions are the same
  mapfile -t INSTANCE_ZONES < <(aws --region "${aws_source_region}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${CONTROL_PLANE_INSTANCE_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 1 ' | awk '{print $2}')
elif [[ "${CONTROL_PLANE_INSTANCE_TYPE}" == null && "${COMPUTE_NODE_TYPE}" == null  ]]; then ## two null regions
  mapfile -t INSTANCE_ZONES < <(aws --region "${aws_source_region}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${CONTROL_PLANE_INSTANCE_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 1 ' | awk '{print $2}')
elif [[ "${CONTROL_PLANE_INSTANCE_TYPE}" == null || "${COMPUTE_NODE_TYPE}" == null ]]; then ## one null region
  if [[ "${BOOTSTRAP_NODE_TYPE}" == "${COMPUTE_NODE_TYPE}" || "${BOOTSTRAP_NODE_TYPE}" == "${CONTROL_PLANE_INSTANCE_TYPE}" || "${CONTROL_PLANE_INSTANCE_TYPE}" == "${COMPUTE_NODE_TYPE}" ]]; then ## "one null region and duplicates"
    mapfile -t INSTANCE_ZONES < <(aws --region "${aws_source_region}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${CONTROL_PLANE_INSTANCE_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 1 ' | awk '{print $2}')
  else ## "one null region and no duplicates"
    mapfile -t INSTANCE_ZONES < <(aws --region "${aws_source_region}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${CONTROL_PLANE_INSTANCE_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 2 ' | awk '{print $2}')
  fi
elif [[ "${BOOTSTRAP_NODE_TYPE}" == "${COMPUTE_NODE_TYPE}" || "${BOOTSTRAP_NODE_TYPE}" == "${CONTROL_PLANE_INSTANCE_TYPE}" || "${CONTROL_PLANE_INSTANCE_TYPE}" == "${COMPUTE_NODE_TYPE}" ]]; then ## duplicates regions with no null region
  mapfile -t INSTANCE_ZONES < <(aws --region "${aws_source_region}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${CONTROL_PLANE_INSTANCE_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 2 ' | awk '{print $2}')
elif [[ "${BOOTSTRAP_NODE_TYPE}" != "${COMPUTE_NODE_TYPE}" && "${COMPUTE_NODE_TYPE}" != "${CONTROL_PLANE_INSTANCE_TYPE}" ]]; then   # three different regions
  mapfile -t INSTANCE_ZONES < <(aws --region "${aws_source_region}" ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values="${BOOTSTRAP_NODE_TYPE}","${CONTROL_PLANE_INSTANCE_TYPE}","${COMPUTE_NODE_TYPE}" | jq -r '.InstanceTypeOfferings[].Location' | sort | uniq -c | grep ' 3 ' | awk '{print $2}')
fi
# Generate availability zones based on these 2 criteria
mapfile -t ZONES < <(echo "${AVAILABILITY_ZONES[@]}" "${INSTANCE_ZONES[@]}" | sed 's/ /\n/g' | sort -R | uniq -d)
# Calculate the maximum number of availability zones from the region
MAX_ZONES_COUNT="${#ZONES[@]}"
# Save max zones count information to ${SHARED_DIR} for use in other scenarios
echo "${MAX_ZONES_COUNT}" >> "${SHARED_DIR}/maxzonescount"

existing_zones_setting=$(yq-go r "${CONFIG}" 'controlPlane.platform.aws.zones')

if [[ ${existing_zones_setting} == "" ]] && [[ ${ADD_ZONES} == "yes" ]]; then
  ZONES_COUNT=${ZONES_COUNT:-2}
  ZONES=("${ZONES[@]:0:${ZONES_COUNT}}")
  ZONES_STR="[ $(join_by , "${ZONES[@]}") ]"
  echo "AWS region: ${REGION} (zones: ${ZONES_STR})"
  PATCH="${SHARED_DIR}/install-config-zones.yaml.patch"
  cat > "${PATCH}" << EOF
controlPlane:
  platform:
    aws:
      zones: ${ZONES_STR}
compute:
- platform:
    aws:
      zones: ${ZONES_STR}
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
else
  echo "zones already set in install-config.yaml, skipped"
fi

echo "Using control plane instance type: ${CONTROL_PLANE_INSTANCE_TYPE}"
echo "Using compute instance type: ${COMPUTE_NODE_TYPE}"
echo "Using compute node replicas: ${worker_replicas}"
echo "Using controlPlane node replicas: ${master_replicas}"

PATCH="${SHARED_DIR}/install-config-common.yaml.patch"
cat > "${PATCH}" << EOF
baseDomain: ${BASE_DOMAIN}
platform:
  aws:
    region: ${REGION}
    userTags:
      expirationDate: ${expiration_date}
controlPlane:
  architecture: ${architecture}
  name: master
  replicas: ${master_replicas}
  platform:
    aws:
      type: ${CONTROL_PLANE_INSTANCE_TYPE}
compute:
- architecture: ${architecture}
  name: worker
  replicas: ${worker_replicas}
  platform:
    aws:
      type: ${COMPUTE_NODE_TYPE}
EOF

yq-go m -x -i "${CONFIG}" "${PATCH}"

printf '%s' "${USER_TAGS:-}" | while read -r TAG VALUE
do
  printf 'Setting user tag %s: %s\n' "${TAG}" "${VALUE}"
  yq-go write -i "${CONFIG}" "platform.aws.userTags.${TAG}" "${VALUE}"
done

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
rm /tmp/pull-secret

# excluding older releases because of the bug fixed in 4.10, see: https://bugzilla.redhat.com/show_bug.cgi?id=1960378
if (( ocp_minor_version > 10 || ocp_major_version > 4 )); then
  MIRROR_REGION="us-east-1"
  if [ "$REGION" == "us-west-1" ] || [ "$REGION" == "us-east-2" ] || [ "$REGION" == "us-west-2" ] ; then
    MIRROR_REGION="${REGION}"
  fi

  PATCH="${SHARED_DIR}/install-config-image-content-sources.yaml.patch"
  cat > "${PATCH}" << EOF
imageContentSources:
- mirrors:
  - quayio-pull-through-cache-${MIRROR_REGION}-ci.apps.ci.l2s4.p1.openshiftapps.com
  source: quay.io
EOF

  yq-go m -x -i "${CONFIG}" "${PATCH}"

  pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
  mirror_auth=$(echo ${pull_secret} | jq '.auths["quay.io"].auth' -r)
  pull_secret_aws=$(jq --arg auth ${mirror_auth} --arg repo "quayio-pull-through-cache-${MIRROR_REGION}-ci.apps.ci.l2s4.p1.openshiftapps.com" '.["auths"] += {($repo): {$auth}}' <<<  $pull_secret)

  PATCH="/tmp/install-config-pull-secret-aws.yaml.patch"
  cat > "${PATCH}" << EOF
pullSecret: >
  $(echo "${pull_secret_aws}" | jq -c .)
EOF
  yq-go m -x -i "${CONFIG}" "${PATCH}"
  rm "${PATCH}"
fi

# custom rhcos ami for non-public regions
RHCOS_AMI=
if [ "$REGION" == "us-gov-west-1" ] || [ "$REGION" == "us-gov-east-1" ] || [ "$REGION" == "cn-north-1" ] || [ "$REGION" == "cn-northwest-1" ]; then
  # TODO: move repo to a more appropriate location
  curl -sL https://raw.githubusercontent.com/yunjiang29/ocp-test-data/main/coreos-for-non-public-regions/images.json -o /tmp/ami.json
  RHCOS_AMI=$(jq -r .architectures.x86_64.images.aws.regions.\"${REGION}\".\"${ocp_version}\".image /tmp/ami.json)
  echo "RHCOS_AMI: $RHCOS_AMI, ocp_version: $ocp_version"
fi

if [[ "${CLUSTER_TYPE}" =~ ^aws-s?c2s$ ]]; then
  jq --version
  if (( ocp_minor_version <= 9 && ocp_major_version == 4 )); then
    # 4.9 and below
    curl -sL https://raw.githubusercontent.com/openshift/installer/release-${ocp_major_version}.${ocp_minor_version}/data/data/rhcos.json -o /tmp/ami.json
    RHCOS_AMI=$(jq --arg r $aws_source_region -r '.amis[$r].hvm' /tmp/ami.json)
  else
    # 4.10 and above
    curl -sL https://raw.githubusercontent.com/openshift/installer/release-${ocp_major_version}.${ocp_minor_version}/data/data/coreos/rhcos.json -o /tmp/ami.json
    RHCOS_AMI=$(jq --arg r $aws_source_region -r '.architectures.x86_64.images.aws.regions[$r].image' /tmp/ami.json)
  fi
  echo "RHCOS for C2S: ${RHCOS_AMI}"
fi

if [ ! -z ${RHCOS_AMI} ]; then
  echo "patching rhcos ami to install-config.yaml"
  CONFIG_PATCH_AMI="${SHARED_DIR}/install-config-ami.yaml.patch"
  cat >> "${CONFIG_PATCH_AMI}" << EOF
platform:
  aws:
    amiID: ${RHCOS_AMI}
EOF
  yq-go m -x -i "${CONFIG}" "${CONFIG_PATCH_AMI}"
  cp "${SHARED_DIR}/install-config-ami.yaml.patch" "${ARTIFACT_DIR}/"
fi


if [[ ${AWS_METADATA_SERVICE_AUTH} =~ ^(Required|Optional)$ ]]; then
  echo "setting up metadata auth in install-config.yaml. Set metadata service auth to: ${AWS_METADATA_SERVICE_AUTH}"
  METADATA_AUTH_PATCH="${SHARED_DIR}/install-config-metadata-auth.yaml.patch"

  cat > "${METADATA_AUTH_PATCH}" << EOF
controlPlane:
  platform:
    aws:
      metadataService:
        authentication: ${AWS_METADATA_SERVICE_AUTH}
compute:
- platform:
    aws:
      metadataService:
        authentication: ${AWS_METADATA_SERVICE_AUTH}
EOF

  yq-go m -x -i "${CONFIG}" "${METADATA_AUTH_PATCH}"
  cp "${METADATA_AUTH_PATCH}" "${ARTIFACT_DIR}/"
fi

if [[ -n "${AWS_EDGE_POOL_ENABLED-}" ]]; then
  edge_zone=$(< "${SHARED_DIR}"/edge-zone-name.txt)
  edge_zones_str="[ $edge_zone ]"
  patch_edge="${SHARED_DIR}/install-config-edge.yaml.patch"
  cat > "${patch_edge}" << EOF
compute:
- architecture: ${architecture}
  name: edge
  platform:
    aws:
      zones: ${edge_zones_str}
EOF
  yq-go m -a -x -i "${CONFIG}" "${patch_edge}"
fi

if [[ "${PRESERVE_BOOTSTRAP_IGNITION}" == "yes" ]]; then
  patch_bootstrap_ignition="${SHARED_DIR}/install-config-bootstrap_ignition.yaml.patch"
  cat > "${patch_bootstrap_ignition}" << EOF
platform:
  aws:
    preserveBootstrapIgnition: true
EOF
  yq-go m -a -x -i "${CONFIG}" "${patch_bootstrap_ignition}"
fi