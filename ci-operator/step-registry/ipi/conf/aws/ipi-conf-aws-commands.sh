#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Version comparison functions using sort -V
function version_le() {
  # Returns 0 (true) if $1 <= $2
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" == "$1" ]]
}

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if [[ ! -r "${CLUSTER_PROFILE_DIR}/baseDomain" ]]; then
  echo "Using default value: ${BASE_DOMAIN}"
  AWS_BASE_DOMAIN="${BASE_DOMAIN}"
else
  AWS_BASE_DOMAIN=$(< ${CLUSTER_PROFILE_DIR}/baseDomain)
fi

CONFIG="${SHARED_DIR}/install-config.yaml"

expiration_date=$(date -d '8 hours' --iso=minutes --utc)

function join_by { local IFS="$1"; shift; echo "$*"; }


# REGION: the region that OCP will be installed
# aws_source_region: for non-C2S/SC2S cluster, it's the same as REGION, for C2S/SC2S it's the source region that emulator runs on.
#             e.g. for instance, if installing a cluster on a C2S (us-iso-east-1) region and its emulator runs on us-east-1:
#                  so the REGION is us-iso-east-1, and aws_source_region is us-east-1
REGION="${AWS_REGION_OVERWRITE:-${LEASED_RESOURCE}}"
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
  # To mitigate the capacity issues, search.dptools.openshift.org can tell us if previous jobs have failed to provision
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
    if err_count=$(curl -L -s "https://search.dptools.openshift.org/search?search=InsufficientInstanceCapacity.*${DESIRED_TYPE}.*${REGION}&maxAge=${LOOK_BACK_PERIOD}&context=0&type=build-log" | jq length); then
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
  CONTROL_ARCH="arm64"
  COMPUTE_ARCH="arm64"

  if [[ "${COMPUTE_NODE_TYPE}" == "" ]]; then
    COMPUTE_NODE_TYPE="m6g.xlarge"
  fi

  if [[ "${CONTROL_PLANE_INSTANCE_TYPE}" == "" ]]; then
    CONTROL_PLANE_INSTANCE_TYPE="m6g.${CONTROL_PLANE_INSTANCE_SIZE}"
  fi
else
  # AMD 64 or Multiarch Compute

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
  if [[ "${CONTROL_ARCH}" == "amd64" ]]; then
    if [[ "${CONTROL_PLANE_INSTANCE_TYPE}" == "" ]]; then
      if [[ "${IS_M6A_REGION}" == "yes" ]]; then
        CONTROL_PLANE_INSTANCE_TYPE=$(eval_instance_capacity "m6a.${CONTROL_PLANE_INSTANCE_SIZE}" "m6i.${CONTROL_PLANE_INSTANCE_SIZE}")
      else
        CONTROL_PLANE_INSTANCE_TYPE="m6i.${CONTROL_PLANE_INSTANCE_SIZE}"
      fi
    fi
  elif [[ "${CONTROL_ARCH}" == "arm64" ]]; then
    CONTROL_PLANE_INSTANCE_TYPE="m6g.${CONTROL_PLANE_INSTANCE_SIZE}"
  else
    echo "${CONTROL_ARCH} is not a valid control plane architecture..."
    exit 1
  fi

  if [[ "${COMPUTE_ARCH}" == "amd64" ]]; then
    if [[ "${COMPUTE_NODE_TYPE}" == "" ]]; then
      if [[ "${IS_M6A_REGION}" == "yes" ]]; then
        COMPUTE_NODE_TYPE=$(eval_instance_capacity "m6a.xlarge" "m6i.xlarge")
      else
        COMPUTE_NODE_TYPE="m6i.xlarge"
      fi
    fi
  elif [[ "${COMPUTE_ARCH}" == "arm64" ]]; then
    COMPUTE_NODE_TYPE="m6g.xlarge"
  else
    echo "${COMPUTE_ARCH} is not a valid compute plane architecture..."
    exit 1
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
  ZONES_COUNT=${ZONES_COUNT:-auto}
  if [[ "${ZONES_COUNT}" == "auto" ]]; then
    if [[ "${JOB_NAME}" == pull-ci-*  || "${JOB_NAME}" == rehearse-*-pull-ci-* ]]; then
      # For presubmits, limit cloud costs by using only one AZ when in "auto".
      ZONES_COUNT="1"
    else
      # For periodics (which inform component readiness), ensure multiple AZ
      # usage in "auto" mode.
      ZONES_COUNT="2"
    fi
  fi
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

# See if we can use NAT instances as a cost reduction method.
if [[ "${CI_NAT_REPLACE:-false}" == 'auto' ]]; then
  # Enable the option for jobs using the shared aws cluster profiles unless they use a different install topology.
  if [[ "${CLUSTER_PROFILE_NAME}" != "aws" && ! "${CLUSTER_PROFILE_NAME}" =~ ^aws-[0-9]+$ ]]; then
    CI_NAT_REPLACE='false_CLUSTER_PROFILE_NAME_is_not_a_testplatform_aws_profile'
  else
    CI_NAT_REPLACE='true'
  fi
fi

if [[ "${CI_NAT_REPLACE:-false}" == 'true' ]]; then
    echo "IMPORTANT: this job has been selected to use NAT instance instead of NAT gateway. See jupierce if abnormalities are detected."
fi

echo "Using control plane instance type: ${CONTROL_PLANE_INSTANCE_TYPE}"
echo "Using compute instance type: ${COMPUTE_NODE_TYPE}"
echo "Using compute node replicas: ${worker_replicas}"
echo "Using controlPlane node replicas: ${master_replicas}"

PATCH="${SHARED_DIR}/install-config-common.yaml.patch"
cat > "${PATCH}" << EOF
baseDomain: ${AWS_BASE_DOMAIN}
platform:
  aws:
    region: ${REGION}
    userTags:
      expirationDate: ${expiration_date}
      clusterName: ${NAMESPACE}-${UNIQUE_HASH}
      ci-nat-replace: "${CI_NAT_REPLACE:-false}"
controlPlane:
  architecture: ${CONTROL_ARCH}
  name: master
  replicas: ${master_replicas}
  platform:
    aws:
      type: ${CONTROL_PLANE_INSTANCE_TYPE}
compute:
- architecture: ${COMPUTE_ARCH}
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

if [[ "${PROPAGATE_USER_TAGS:-}" == "yes" ]]; then
  patch_propagate_user_tags="${SHARED_DIR}/install-config-propagate_user_tags.yaml.patch"
  cat > "${patch_propagate_user_tags}" << EOF
platform:
  aws:
    propagateUserTags: true
EOF
  yq-go m -a -x -i "${CONFIG}" "${patch_propagate_user_tags}"
fi

cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )
rm /tmp/pull-secret

# excluding older releases because of the bug fixed in 4.10, see: https://bugzilla.redhat.com/show_bug.cgi?id=1960378
# if (( ocp_minor_version > 10 || ocp_major_version > 4 )); then
#   PATCH="${SHARED_DIR}/install-config-image-content-sources.yaml.patch"
#   cat > "${PATCH}" << EOF
# imageContentSources:
# - mirrors:
#   - quayio-pull-through-cache-gcs-ci.apps.ci.l2s4.p1.openshiftapps.com
#   source: quay.io
# EOF

#   yq-go m -x -i "${CONFIG}" "${PATCH}"

#   pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
#   mirror_auth=$(echo ${pull_secret} | jq '.auths["quay.io"].auth' -r)
#   pull_secret_aws=$(jq --arg auth ${mirror_auth} --arg repo "quayio-pull-through-cache-gcs-ci.apps.ci.l2s4.p1.openshiftapps.com" '.["auths"] += {($repo): {$auth}}' <<<  $pull_secret)

#   PATCH="/tmp/install-config-pull-secret-aws.yaml.patch"
#   cat > "${PATCH}" << EOF
# pullSecret: >
#   $(echo "${pull_secret_aws}" | jq -c .)
# EOF
#   yq-go m -x -i "${CONFIG}" "${PATCH}"
#   rm "${PATCH}"
# fi

# custom rhcos ami for non-public regions
if [[ "${CLUSTER_TYPE}" =~ ^aws-s?c2s$ ]] && [[ -z "${CONTROL_PLANE_AMI}" ]] && [[ -z "${COMPUTE_AMI}" ]]; then
  jq --version
  if version_le "${ocp_version}" "4.9"; then
    # 4.9 and below
    curl -sL https://raw.githubusercontent.com/openshift/installer/release-${ocp_major_version}.${ocp_minor_version}/data/data/rhcos.json -o /tmp/ami.json
    CONTROL_PLANE_AMI=$(jq --arg r $aws_source_region -r '.amis[$r].hvm' /tmp/ami.json)
  elif version_le "${ocp_version}" "4.21"; then
    # 4.10 to 4.21
    curl -sL https://raw.githubusercontent.com/openshift/installer/release-${ocp_major_version}.${ocp_minor_version}/data/data/coreos/rhcos.json -o /tmp/ami.json
    CONTROL_PLANE_AMI=$(jq --arg r $aws_source_region -r '.architectures.x86_64.images.aws.regions[$r].image' /tmp/ami.json)
  else
    # 4.22 and above: rhcos.json was split into coreos-rhel-9.json and coreos-rhel-10.json
    coreos_file="coreos-rhel-9.json"
    if [[ "${OS_IMAGE_STREAM:-}" == "rhel-10" ]]; then
      coreos_file="coreos-rhel-10.json"
    fi
    curl -sL https://raw.githubusercontent.com/openshift/installer/release-${ocp_major_version}.${ocp_minor_version}/data/data/coreos/${coreos_file} -o /tmp/ami.json
    CONTROL_PLANE_AMI=$(jq --arg r $aws_source_region -r '.architectures.x86_64.images.aws.regions[$r].image' /tmp/ami.json)
  fi
  COMPUTE_AMI="${CONTROL_PLANE_AMI}"
  echo "RHCOS for C2S: ${CONTROL_PLANE_AMI}"
fi

# Apply AMI configuration
if [[ -n "${CONTROL_PLANE_AMI}" ]]; then
  echo "Setting control plane AMI: ${CONTROL_PLANE_AMI}"
  yq-v4 eval -i '.controlPlane.platform.aws.amiID = env(CONTROL_PLANE_AMI)' "${CONFIG}"
fi

if [[ -n "${COMPUTE_AMI}" ]]; then
  echo "Setting compute AMI: ${COMPUTE_AMI}"
  yq-v4 eval -i '.compute[0].platform.aws.amiID = env(COMPUTE_AMI)' "${CONFIG}"
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
  edge_zones=""
  while IFS= read -r line; do
    if [[ -z "${edge_zones}" ]]; then
      edge_zones="$line";
    else
      edge_zones+=",$line";
    fi
  done < <(grep -v '^$' < "${SHARED_DIR}"/edge-zone-names.txt)

  edge_zones_str="[ $edge_zones ]"
  patch_edge="${SHARED_DIR}/install-config-edge.yaml.patch"
  cat > "${patch_edge}" << EOF
compute:
- architecture: ${COMPUTE_ARCH}
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

if [[ "${USER_PROVISIONED_DNS}" == "yes" ]]; then
  patch_user_provisioned_dns="${SHARED_DIR}/install-config-user-provisioned-dns.yaml.patch"
  cat > "${patch_user_provisioned_dns}" << EOF
platform:
  aws:
    userProvisionedDNS: Enabled
EOF
  yq-go m -a -x -i "${CONFIG}" "${patch_user_provisioned_dns}"
fi

# Add config for dedicated hosts to compute nodes if job is configured
if [[ "${DEDICATED_HOST}" == "yes" ]]; then
  echo "Detected dedicated host configured.  Starting install-config patching."
  patch_dedicated_host="${SHARED_DIR}/install-config-dedicated-host.yaml.patch"

  # Create Host for each zone.  If no zones configured, error out.  Zones can exist before script execution so we'll pull zone listing out for workers.
  WORKER_ZONES=$(cat "${CONFIG}" | yq-v4 '.compute[] | select(.name == "worker") | .platform.aws.zones'[] )
  if [[ "${WORKER_ZONES}" == "" ]]; then
    echo "No zones configured,  Unable to determine where to create dedicated hosts."
    exit
  fi

  cat > "${patch_dedicated_host}" << EOF
compute:
- name: worker
  platform:
    aws:
      hostPlacement:
        affinity: DedicatedHost
        dedicatedHost: []
EOF

  HOST_TYPE=$(echo "${COMPUTE_NODE_TYPE}" | cut -d'.' -f1)
  USAGE_TAG_KEY="in-use-by-${BUILD_ID}"
  FOUND_HOST=""
  FOUND_ZONE=""

  # First, check for existing available dedicated hosts in any zone
  echo "Searching for existing available dedicated hosts in region '${aws_source_region}'..."

  # Query all dedicated hosts for this instance family
  EXISTING_HOSTS=$(aws ec2 describe-hosts \
    --region "${aws_source_region}" \
    --filter "Name=instance-type,Values=${COMPUTE_NODE_TYPE}" "Name=state,Values=available" \
    --query 'Hosts[*].[HostId,AvailabilityZone,Tags]' \
    --output json)

  if [[ "${EXISTING_HOSTS}" != "[]" && "${EXISTING_HOSTS}" != "" ]]; then
    echo "Found existing hosts, checking availability..."

    # Iterate through existing hosts to find one that's available
    for row in $(echo "${EXISTING_HOSTS}" | jq -r '.[] | @base64'); do
      _jq() {
        echo "${row}" | base64 --decode | jq -r "${1}"
      }

      CANDIDATE_HOST=$(_jq '.[0]')
      CANDIDATE_ZONE=$(_jq '.[1]')
      CANDIDATE_TAGS=$(_jq '.[2]')

      # Check if this host is in one of our worker zones
      if echo "${WORKER_ZONES}" | grep -qw "${CANDIDATE_ZONE}"; then
        # Check if host has any active usage tags (in-use-by-*)
        IN_USE=$(echo "${CANDIDATE_TAGS}" | jq -r 'map(select(.Key | startswith("in-use-by-"))) | length')

        if [[ "${IN_USE}" == "0" ]]; then
          echo "Found available host ${CANDIDATE_HOST} in zone ${CANDIDATE_ZONE}"
          FOUND_HOST="${CANDIDATE_HOST}"
          FOUND_ZONE="${CANDIDATE_ZONE}"
          break
        fi
      fi
    done
  fi

  # If we found an available host, claim it; otherwise create a new one
  if [[ -n "${FOUND_HOST}" ]]; then
    echo "Claiming existing host ${FOUND_HOST} in zone ${FOUND_ZONE}"
    HOST_ID="${FOUND_HOST}"
    zone="${FOUND_ZONE}"

    # Tag the host with our job's usage tag
    aws ec2 create-tags \
      --region "${aws_source_region}" \
      --resources "${HOST_ID}" \
      --tags "Key=${USAGE_TAG_KEY},Value=${JOB_NAME_SAFE}"
  else
    # No available host found, try to allocate a new one in the first available zone
    echo "No available existing hosts found. Attempting to allocate new host..."
    HOST_ID=""
    zone=""

    for candidate_zone in ${WORKER_ZONES}; do
      echo "Attempting to allocate dedicated host in zone '${candidate_zone}'..."

      EXPIRATION_DATE=$(date -d '6 hours' --iso=minutes --utc)
      HOST_SPECS='{"ResourceType":"dedicated-host","Tags":[{"Key":"Name","Value":"ci-shared-'${HOST_TYPE}'"},{"Key":"instance-family","Value":"'${HOST_TYPE}'"},{"Key":"expirationDate","Value":"'${EXPIRATION_DATE}'"},{"Key":"'${USAGE_TAG_KEY}'","Value":"'${JOB_NAME_SAFE}'"}]}'

      # Try to allocate the host
      if HOST_RESULT=$(aws ec2 allocate-hosts \
        --instance-type "${COMPUTE_NODE_TYPE}" \
        --auto-placement 'off' \
        --host-recovery 'off' \
        --tag-specifications "${HOST_SPECS}" \
        --host-maintenance 'off' \
        --quantity '1' \
        --availability-zone "${candidate_zone}" \
        --region "${aws_source_region}" 2>&1); then

        HOST_ID=$(echo "${HOST_RESULT}" | jq -r '.HostIds[0]')
        zone="${candidate_zone}"
        echo "Successfully allocated host ${HOST_ID} in zone ${zone}"
        break
      else
        echo "Failed to allocate host in zone ${candidate_zone}: ${HOST_RESULT}"
      fi
    done

    if [[ -z "${HOST_ID}" ]]; then
      echo "ERROR: Failed to allocate dedicated host in any zone"
      exit 1
    fi
  fi

  # We need to pass in the vars since YQ doesnt see the loop variables
  HOST_ID="${HOST_ID}" yq-v4 -i '.compute[] |= (select(.name == "worker") | .platform.aws.hostPlacement.dedicatedHost += [ { "id": strenv(HOST_ID) } ])' "${patch_dedicated_host}"

  # Save the usage tag key for deprovision step
  echo "${USAGE_TAG_KEY}" > "${SHARED_DIR}/dedicated-host-usage-tag"

  # Update config with host ID
  echo "Patching install-config.yaml for dedicated hosts."
  yq-go m -x -i ${CONFIG} ${patch_dedicated_host}
  cp "${patch_dedicated_host}" "${ARTIFACT_DIR}/"
fi

# Configure dual-stack networking if IP_FAMILY is set
if [[ -n "${IP_FAMILY:-}" ]]; then
  echo "Configuring AWS dual-stack networking with ipFamily: ${IP_FAMILY}"
  patch_dualstack="${SHARED_DIR}/install-config-dualstack.yaml.patch"

  # For IPv6Primary, IPv6 addresses must be listed first
  if [[ "${IP_FAMILY}" == "DualStackIPv6Primary" ]]; then
    cat > "${patch_dualstack}" << EOF
platform:
  aws:
    ipFamily: ${IP_FAMILY}
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 10.0.0.0/16
  clusterNetwork:
  - cidr: fd01::/48
    hostPrefix: 64
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - fd02::/112
  - 172.30.0.0/16
EOF
  else
    # DualStackIPv4Primary or default - IPv4 addresses listed first
    cat > "${patch_dualstack}" << EOF
platform:
  aws:
    ipFamily: ${IP_FAMILY}
networking:
  networkType: OVNKubernetes
  machineNetwork:
  - cidr: 10.0.0.0/16
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  - cidr: fd01::/48
    hostPrefix: 64
  serviceNetwork:
  - 172.30.0.0/16
  - fd02::/112
EOF
  fi

  # byo-vpc
  vpc_info_json=${SHARED_DIR}/vpc_info.json
  if [ -f "$vpc_info_json" ]; then
    vpc_ipv4_cidr=$(jq -r '.vpc_ipv4_cidr' "$vpc_info_json")
    vpc_ipv6_cidr=$(jq -r '.vpc_ipv6_cidr' "$vpc_info_json")
    export vpc_ipv4_cidr
    export vpc_ipv6_cidr
    if [[ "${IP_FAMILY}" == "DualStackIPv6Primary" ]]; then
      yq-v4 eval -i '.networking.machineNetwork[0].cidr = env(vpc_ipv6_cidr)' ${patch_dualstack}
      yq-v4 eval -i '.networking.machineNetwork[1].cidr = env(vpc_ipv4_cidr)' ${patch_dualstack}
    else
      yq-v4 eval -i '.networking.machineNetwork[0].cidr = env(vpc_ipv4_cidr)' ${patch_dualstack}
      yq-v4 eval -i '.networking.machineNetwork[1].cidr = env(vpc_ipv6_cidr)' ${patch_dualstack}
    fi
  fi

  yq-go m -a -x -i "${CONFIG}" "${patch_dualstack}"
  cp "${patch_dualstack}" "${ARTIFACT_DIR}/"
  echo "Dual-stack networking configuration added to install-config.yaml"
fi

# Configure PKI signer certificates if PKI_ALGORITHM is set
if [[ -n "${PKI_ALGORITHM:-}" ]]; then
  echo "Configuring PKI with algorithm: ${PKI_ALGORITHM}"
  patch_pki="${SHARED_DIR}/install-config-pki.yaml.patch"
  case "${PKI_ALGORITHM}" in
    RSA)
      cat > "${patch_pki}" << EOF
pki:
  signerCertificates:
    key:
      algorithm: RSA
      rsa:
        keySize: ${PKI_RSA_KEY_SIZE}
EOF
      ;;
    ECDSA)
      cat > "${patch_pki}" << EOF
pki:
  signerCertificates:
    key:
      algorithm: ECDSA
      ecdsa:
        curve: ${PKI_ECDSA_CURVE}
EOF
      ;;
    *)
      echo "ERROR: Unsupported PKI_ALGORITHM: ${PKI_ALGORITHM}. Must be RSA or ECDSA."
      exit 1
      ;;
  esac
  yq-go m -x -i "${CONFIG}" "${patch_pki}"
  cp "${patch_pki}" "${ARTIFACT_DIR}/"
  echo "PKI configuration added to install-config.yaml"
fi
