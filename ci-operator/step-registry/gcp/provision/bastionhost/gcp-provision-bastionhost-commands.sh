#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' EXIT TERM

function run_ssh_cmd() {
    local sshkey=$1
    local user=$2
    local host=$3
    local remote_cmd=$4

    options=" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=300 -o ServerAliveCountMax=10 "
    cmd="ssh ${options} -i \"${sshkey}\" ${user}@${host} \"${remote_cmd}\""
    eval "$cmd" || return 2
}

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
bastion_ignition_file="${SHARED_DIR}/${CLUSTER_NAME}-bastion.ign"
SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey

if [[ ! -f "${bastion_ignition_file}" ]]; then
  echo "'${bastion_ignition_file}' not found, abort." && exit 1
fi

if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  echo "Reading variables from ${SHARED_DIR}/xpn.json..."
  NETWORK="$(jq -r '.clusterNetwork' "${SHARED_DIR}/xpn.json")"
  CONTROL_PLANE_SUBNET="$(jq -r '.controlSubnet' "${SHARED_DIR}/xpn.json")"
fi

if [[ -s "${SHARED_DIR}/customer_vpc_subnets.yaml" ]]; then
  NETWORK=$(yq-go r "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.gcp.network')
  CONTROL_PLANE_SUBNET=$(yq-go r "${SHARED_DIR}/customer_vpc_subnets.yaml" 'platform.gcp.controlPlaneSubnet')
fi

if [[ -z "${NETWORK}" || -z "${CONTROL_PLANE_SUBNET}" ]]; then
  echo "Could not find VPC network and control-plane subnet" && exit 1
fi

#####################################
##############Initialize#############
#####################################
workdir=`mktemp -d`

# Generally we do not update boot image for bastion host very often, we just use it as a jump
# host, mirror registry, and proxy server, these services do not have frequent update.
# So hard-code them here.
IMAGE_NAME="fedora-coreos-41-20241122-3-0-gcp-x86-64"
IMAGE_PROJECT="fedora-coreos-cloud"
echo "Using ${IMAGE_NAME} image from ${IMAGE_PROJECT} project"

#####################################
###############Log In################
#####################################

if [[ -s "${SHARED_DIR}/xpn.json" ]] && [[ -f "${CLUSTER_PROFILE_DIR}/xpn_creds.json" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Activating XPN service-account..."
  GOOGLE_CLOUD_XPN_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/xpn_creds.json"
  gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_XPN_KEYFILE_JSON}"
  GOOGLE_CLOUD_XPN_SA=$(jq -r .client_email "${GOOGLE_CLOUD_XPN_KEYFILE_JSON}")
fi
if [[ "${OSD_QE_PROJECT_AS_SERVICE_PROJECT}" == "yes" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Activating OSD QE service account & project..."
  export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/osd-ccs-gcp.json"
  GOOGLE_PROJECT_ID="$(jq -r -c .project_id "${GCP_SHARED_CREDENTIALS_FILE}")"
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
else
  GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
  export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
  sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
  if ! gcloud auth list | grep -E "\*\s+${sa_email}"
  then
    gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
    gcloud config set project "${GOOGLE_PROJECT_ID}"
  fi
fi

REGION="${LEASED_RESOURCE}"
echo "Using region: ${REGION}"

ZONE_0=$(gcloud compute regions describe ${REGION} --format=json | jq -r .zones[0] | cut -d "/" -f9)
MACHINE_TYPE="n2-standard-2"

#####################################
##########Create Bastion#############
#####################################
bastion_name="${CLUSTER_NAME}-bastion"
CMD="gcloud compute instances create ${bastion_name} \
  --hostname=${bastion_name}.test.com \
  --image=${IMAGE_NAME} \
  --image-project=${IMAGE_PROJECT} \
  --boot-disk-size=200GB \
  --metadata-from-file=user-data=${bastion_ignition_file} \
  --machine-type=${MACHINE_TYPE} \
  --network=${NETWORK} \
  --subnet=${CONTROL_PLANE_SUBNET} \
  --zone=${ZONE_0} \
  --tags=${bastion_name}"

if [ -n "${ATTACH_BASTION_SA}" ]; then
  CMD="${CMD} --service-account ${ATTACH_BASTION_SA} --scopes cloud-platform"
fi
if [[ "${OSD_QE_PROJECT_AS_SERVICE_PROJECT}" == "yes" ]]; then
  CMD="${CMD} --shielded-secure-boot"
fi
echo "Running Command: ${CMD}"
eval "${CMD}"

echo "Created bastion instance"
echo "Waiting for the proxy service starting running..." && sleep 60s

if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  project_option="--project=${HOST_PROJECT} --account ${GOOGLE_CLOUD_XPN_SA}"
else
  project_option=""
fi
gcloud ${project_option} compute firewall-rules create "${bastion_name}-ingress-allow" \
  --network ${NETWORK} \
  --allow tcp:22,tcp:3128,tcp:3129,tcp:5000,tcp:6001,tcp:6002,tcp:8080,tcp:873 \
  --target-tags="${bastion_name}"
cat > "${SHARED_DIR}/bastion-destroy.sh" << EOF
gcloud compute instances delete -q "${bastion_name}" --zone=${ZONE_0}
gcloud ${project_option} compute firewall-rules delete -q "${bastion_name}-ingress-allow"
EOF

#####################################
#########Save Bastion Info###########
#####################################
echo "Instance ${bastion_name}"
# to allow log collection during gather:
# append to proxy instance ID to "${SHARED_DIR}/gcp-instance-ids.txt"
echo "${bastion_name}" >> "${SHARED_DIR}/gcp-instance-ids.txt"

gcloud compute instances list --filter="name=${bastion_name}" \
  --zones "${ZONE_0}" --format json > "${workdir}/${bastion_name}.json"
bastion_private_ip="$(jq -r '.[].networkInterfaces[0].networkIP' ${workdir}/${bastion_name}.json)"
bastion_public_ip="$(jq -r '.[].networkInterfaces[0].accessConfigs[0].natIP' ${workdir}/${bastion_name}.json)"

if [ X"${bastion_public_ip}" == X"" ] || [ X"${bastion_private_ip}" == X"" ] ; then
    echo "Did not found public or internal IP!"
    exit 1
fi
echo ${bastion_public_ip} > "${SHARED_DIR}/bastion_public_address"
echo ${bastion_private_ip} > "${SHARED_DIR}/bastion_private_address"
echo "core" > "${SHARED_DIR}/bastion_ssh_user"

src_proxy_creds_file="/var/run/vault/proxy/proxy_creds"
proxy_credential=$(cat "${src_proxy_creds_file}")
proxy_public_url="http://${proxy_credential}@${bastion_public_ip}:3128"
proxy_private_url="http://${proxy_credential}@${bastion_private_ip}:3128"
echo "${proxy_public_url}" > "${SHARED_DIR}/proxy_public_url"
echo "${proxy_private_url}" > "${SHARED_DIR}/proxy_private_url"

# echo proxy IP to ${SHARED_DIR}/proxyip
echo "${bastion_public_ip}" > "${SHARED_DIR}/proxyip"

#####################################
####Register mirror registry DNS#####
#####################################
if [[ "${REGISTER_MIRROR_REGISTRY_DNS}" == "yes" ]]; then
  BASE_DOMAIN="$(< ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
  BASE_DOMAIN_ZONE_NAME="$(gcloud dns managed-zones list --filter "DNS_NAME=${BASE_DOMAIN}." --format json | jq -r .[0].name)"

  echo "Configuring public DNS for the mirror registry..."
  gcloud dns record-sets create "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." \
  --rrdatas="${bastion_public_ip}" --type=A --ttl=60 --zone="${BASE_DOMAIN_ZONE_NAME}"

  echo "Configuring private DNS for the mirror registry..."
  gcloud dns managed-zones create "${CLUSTER_NAME}-mirror-registry-private-zone" \
  --description "Private zone for the mirror registry." \
  --dns-name "mirror-registry.${BASE_DOMAIN}." --visibility "private" --networks "${NETWORK}"
  gcloud dns record-sets create "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." \
  --rrdatas="${bastion_private_ip}" --type=A --ttl=60 --zone="${CLUSTER_NAME}-mirror-registry-private-zone"

  cat > "${SHARED_DIR}/mirror-dns-destroy.sh" << EOF
  gcloud dns record-sets delete -q "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." --type=A --zone="${BASE_DOMAIN_ZONE_NAME}"
  gcloud dns record-sets delete -q "${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}." --type=A --zone="${CLUSTER_NAME}-mirror-registry-private-zone"
  gcloud dns managed-zones delete -q "${CLUSTER_NAME}-mirror-registry-private-zone"
EOF

  echo "Waiting for ${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN} taking effect..." && sleep 120s

  MIRROR_REGISTRY_URL="${CLUSTER_NAME}.mirror-registry.${BASE_DOMAIN}:5000"
  echo "${MIRROR_REGISTRY_URL}" > "${SHARED_DIR}/mirror_registry_url"
fi

#####################################
##############Clean Up###############
#####################################
rm -rf "${workdir}"

echo "Sleeping 5 mins, make sure that the bastion host is fully started."
sleep 300

if [[ -f "${SHARED_DIR}/gcp_custom_endpoint" ]]; then
  gcp_custom_endpoint=$(< "${SHARED_DIR}/gcp_custom_endpoint")
  gcp_custom_endpoint_ip_address=$(< "${SHARED_DIR}/gcp_custom_endpoint_ip_address")

  echo "$(date -u --rfc-3339=seconds) - Ensure GCP custom endpoint '${gcp_custom_endpoint}' is accessible..."

  declare -a services=("compute" "container" "dns" "file" "iam" "serviceusage" "cloudresourcemanager" "storage")
  test_cmd=""
  for service_name in "${services[@]}"
  do
    test_cmd="${test_cmd} dig +short ${service_name}-${gcp_custom_endpoint}.p.googleapis.com;"
  done
  count=0
  dig_result=""

  set +e
  for i in {1..20}
  do
    dig_result=$(run_ssh_cmd "${SSH_PRIV_KEY_PATH}" core "${bastion_public_ip}" "${test_cmd}")
    count=$(echo "${dig_result}" | grep -c "${gcp_custom_endpoint_ip_address}")
    if [[ ${count} -eq "${#services[@]}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - [$i] The custom endpoint turns accessible."
      break
    else
      echo "$(date -u --rfc-3339=seconds) - [$i] Waiting for another 60 seconds..."
      sleep 60s
    fi
  done
  set -e

  if [[ ${count} -ne "${#services[@]}" ]]; then
    echo "$(date -u --rfc-3339=seconds) - ERROR: Failed to wait for the custom endpoint turning into accessible, abort. " && exit 1
  fi
fi
