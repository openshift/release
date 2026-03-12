#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

if test -f "/var/lib/openshift-install/upi/gcp/01_vpc/01_vpc.tf"; then

  echo "$(date -u --rfc-3339=seconds) - INFO: infra-manager resource files found from 'upi-installer' !"

else

  echo "$(date -u --rfc-3339=seconds) - INFO: infra-manager resource files not found, nothing to do."
  exit 0

fi

export HOME=/tmp

export SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}"

# release-controller always expose RELEASE_IMAGE_LATEST when job configuraiton defines release:latest image
echo "RELEASE_IMAGE_LATEST: ${RELEASE_IMAGE_LATEST:-}"
# seem like release-controller does not expose RELEASE_IMAGE_INITIAL, even job configuraiton defines 
# release:initial image, once that, use 'oc get istag release:inital' to workaround it.
echo "RELEASE_IMAGE_INITIAL: ${RELEASE_IMAGE_INITIAL:-}"
if [[ -n ${RELEASE_IMAGE_INITIAL:-} ]]; then
  tmp_release_image_initial=${RELEASE_IMAGE_INITIAL}
  echo "Getting inital release image from RELEASE_IMAGE_INITIAL..."
elif oc get istag "release:initial" -n ${NAMESPACE} &>/dev/null; then
  tmp_release_image_initial=$(oc -n ${NAMESPACE} get istag "release:initial" -o jsonpath='{.tag.from.name}')
  echo "Getting inital release image from build farm imagestream: ${tmp_release_image_initial}"
fi
# For some ci upgrade job (stable N -> nightly N+1), RELEASE_IMAGE_INITIAL and 
# RELEASE_IMAGE_LATEST are pointed to different imgaes, RELEASE_IMAGE_INITIAL has 
# higher priority than RELEASE_IMAGE_LATEST
TESTING_RELEASE_IMAGE=""
if [[ -n ${tmp_release_image_initial:-} ]]; then
  TESTING_RELEASE_IMAGE=${tmp_release_image_initial}
else
  TESTING_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST}
fi
echo "TESTING_RELEASE_IMAGE: ${TESTING_RELEASE_IMAGE}"

# check if OCP version will be equal to or greater than the minimum version
# $1 - the minimum version to be compared with
# return 0 if OCP version >= the minimum version, otherwise 1
function version_check() {
  local -r minimum_version="$1"
  local ret

  dir=$(mktemp -d)
  pushd "${dir}"

  cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
  KUBECONFIG="" oc registry login --to pull-secret
  ocp_version=$(oc adm release info --registry-config pull-secret ${TESTING_RELEASE_IMAGE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
  rm pull-secret

  echo "[DEBUG] minimum OCP version: '${minimum_version}'"
  echo "[DEBUG] current OCP version: '${ocp_version}'"
  curr_x=$(echo "${ocp_version}" | cut -d. -f1)
  curr_y=$(echo "${ocp_version}" | cut -d. -f2)
  min_x=$(echo "${minimum_version}" | cut -d. -f1)
  min_y=$(echo "${minimum_version}" | cut -d. -f2)

  if [ ${curr_x} -gt ${min_x} ] || ( [ ${curr_x} -eq ${min_x} ] && [ ${curr_y} -ge ${min_y} ] ); then
    echo "[DEBUG] version_check result: ${ocp_version} >= ${minimum_version}"
    ret=0
  else
    echo "[DEBUG] version_check result: ${ocp_version} < ${minimum_version}"
    ret=1
  fi

  popd
  return ${ret}
}

function short_wait()
{
  local seconds=3

  if [[ $# -gt 0 ]]; then
    seconds=$1
  fi

  echo "$(date -u --rfc-3339=seconds) - Sleeping for ${seconds} seconds..."
  sleep "${seconds}s"
}

function infra_manager_debug()
{
  local -r deployment_name="$1"; shift
  local -r cmd_ret="$1"; shift
  local CMD

  set +e
  echo "$(date -u --rfc-3339=seconds) - Debugging for infrastructure manager deployment '${deployment_name}' (${cmd_ret})"
  CMD="gcloud infra-manager deployments describe ${deployment_name} --location=${REGION}"
  run_command "${CMD}"
  set -e

  echo "$(date -u --rfc-3339=seconds) - Should exit for command code '${cmd_ret}'"
  exit ${cmd_ret}
}

function run_command() {
  local CMD="$1"
  echo "$(date -u --rfc-3339=seconds) - Running command: ${CMD}"
  eval "${CMD}"
}

function create_vpc()
{
  local -r subnet1_cidr="$1"; shift
  local -r subnet2_cidr="$1"; shift
  local CMD="" cmd_ret=0

  CMD="gcloud infra-manager deployments apply ${CLUSTER_NAME}-${UPI_RESOURCE_DIR_VPC//_/-} --location=${REGION} --input-values=infra_id=${INFRA_ID},project=${PROJECT_NAME},region=${REGION},master_subnet_cidr=${subnet1_cidr},worker_subnet_cidr=${subnet2_cidr} --project=${PROJECT_NAME} --service-account=${INSTALL_SERVICE_ACCOUNT}"
  CMD="${CMD} ${SOURCE_OPTIONS}/${UPI_RESOURCE_DIR_VPC}"
  run_command "${CMD}" || cmd_ret=$?
  if [ $cmd_ret -ne 0 ]; then
    infra_manager_debug "${CLUSTER_NAME}-${UPI_RESOURCE_DIR_VPC//_/-}" "${REGION}" $cmd_ret
  fi
}

echo "$(date -u --rfc-3339=seconds) - Configuring gcloud..."
if version_check "4.11"; then
  GCLOUD_SDK_VERSION="563"
else
  GCLOUD_SDK_VERSION="256"
fi
gcloud version
if ! gcloud version | grep -q "Google Cloud SDK ${GCLOUD_SDK_VERSION}"; then
  GCLOUD_TAR="google-cloud-sdk-${GCLOUD_SDK_VERSION}.0.0-linux-x86_64.tar.gz"
  GCLOUD_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$GCLOUD_TAR"
  echo "$(date -u --rfc-3339=seconds) - gcloud expected version not installed: installing from $GCLOUD_URL"
  pushd ${HOME}
  curl -O "$GCLOUD_URL"
  tar -xzf "$GCLOUD_TAR"
  export PATH=${HOME}/google-cloud-sdk/bin:${PATH}
  popd
fi
gcloud version
echo "$(date -u --rfc-3339=seconds) - Unset env var 'CLOUDSDK_PYTHON', use gcloud bundled-python3-unix instead"
unset CLOUDSDK_PYTHON

if [[ -s "${SHARED_DIR}/xpn.json" ]] && [[ -f "${CLUSTER_PROFILE_DIR}/xpn_creds.json" ]]; then
  echo "Activating XPN service-account..."
  GOOGLE_CLOUD_XPN_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/xpn_creds.json"
  gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_XPN_KEYFILE_JSON}"
  GOOGLE_CLOUD_XPN_SA=$(jq -r .client_email "${GOOGLE_CLOUD_XPN_KEYFILE_JSON}")
fi
export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/installer-qe-upi-admin.json"
gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"
gcloud config set project "$(jq -r .gcp.projectID "${SHARED_DIR}/metadata.json")"
INSTALL_SERVICE_ACCOUNT="projects/$(jq -r .gcp.projectID ${SHARED_DIR}/metadata.json)/serviceAccounts/$(jq -r .client_email ${GOOGLE_CLOUD_KEYFILE_JSON})"

echo "$(date -u --rfc-3339=seconds) - Copying config from shared dir..."
dir=/tmp/installer
mkdir -p "${dir}/auth"
pushd "${dir}"
cp -t "${dir}" \
    "${SHARED_DIR}/install-config.yaml" \
    "${SHARED_DIR}/metadata.json" \
    "${SHARED_DIR}"/*.ign
cp -t "${dir}/auth" \
    "${SHARED_DIR}/kubeadmin-password" \
    "${SHARED_DIR}/kubeconfig"
cp -t "${dir}" -r \
    "/var/lib/openshift-install/upi/${CLUSTER_TYPE}"
tar -xzf "${SHARED_DIR}/.openshift_install_state.json.tgz"

# UPI resources directory names
UPI_RESOURCE_DIR_VPC="01_vpc"
UPI_RESOURCE_DIR_INFRA_DNS_PRIV_ZONE="02_dns"
UPI_RESOURCE_DIR_INFRA_INTERNAL_LB="02_lb_int"
UPI_RESOURCE_DIR_INFRA_EXTERNAL_LB="02_lb_ext"
UPI_RESOURCE_DIR_SECURITY="03_security"
UPI_RESOURCE_DIR_BOOTSTRAP="04_bootstrap"
UPI_RESOURCE_DIR_CONTROL_PLANE="05_control_plane"
UPI_RESOURCE_DIR_WORKER="06_worker"

GCP_UPI_SOURCE_FILES_DIR="${dir}/gcp"
SOURCE_OPTIONS="--local-source=${GCP_UPI_SOURCE_FILES_DIR}"

function backoff() {
    local attempt=0
    local failed=0
    while true; do
        eval "$*" && failed=0 || failed=1
        if [[ $failed -eq 0 ]]; then
            break
        fi
        attempt=$(( attempt + 1 ))
        if [[ $attempt -gt 5 ]]; then
            break
        fi
        echo "command failed, retrying in $(( 2 ** attempt )) seconds"
        sleep $(( 2 ** attempt ))
    done
    return $failed
}

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"

## Export variables to be used in examples below.
echo "$(date -u --rfc-3339=seconds) - Exporting variables..."
BASE_DOMAIN="$(cat ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
BASE_DOMAIN_ZONE_NAME="$(gcloud dns managed-zones list --filter "DNS_NAME=${BASE_DOMAIN}." --format json | jq -r .[0].name)"
NETWORK_CIDR='10.0.0.0/16'
MASTER_SUBNET_CIDR='10.0.0.0/19'
WORKER_SUBNET_CIDR='10.0.32.0/19'

KUBECONFIG="${dir}/auth/kubeconfig"
export KUBECONFIG
CLUSTER_NAME="$(jq -r .clusterName metadata.json)"
INFRA_ID="$(jq -r .infraID metadata.json)"
PROJECT_NAME="$(jq -r .gcp.projectID metadata.json)"
REGION="$(jq -r .gcp.region metadata.json)"

## Available zones and instance zones might be different in region for arm64 machines
mapfile -t AVAILABILITY_ZONES < <(gcloud compute regions describe "${REGION}" --format=json | jq -r '.zones[]' | cut -d "/" -f9)
mapfile -t MASTER_INSTANCE_ZONES < <(gcloud compute machine-types list --filter="zone:(${REGION}) AND name=(${CONTROL_PLANE_NODE_TYPE})" --format=json | jq -r '.[].zone')
mapfile -t MASTER_ZONES < <(echo "${AVAILABILITY_ZONES[@]}" "${MASTER_INSTANCE_ZONES[@]}" | sed 's/ /\n/g' | sort -R | uniq -d)
for index in {0..2}; do
  eval ZONE_${index}=${MASTER_ZONES[index]}
done

echo "Using infra_id: ${INFRA_ID}"

### Read XPN config, if exists
HOST_PROJECT="${PROJECT_NAME}"
PROJECT_OPTION="--project ${HOST_PROJECT}"
if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  echo "Reading variables from ${SHARED_DIR}/xpn.json..."
  IS_XPN=1
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  PROJECT_OPTION="--project ${HOST_PROJECT}"
  HOST_PROJECT_NETWORK="$(jq -r '.clusterNetwork' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_COMPUTE_SUBNET="$(jq -r '.computeSubnet' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_CONTROL_SUBNET="$(jq -r '.controlSubnet' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_COMPUTE_SERVICE_ACCOUNT="$(jq -r '.computeServiceAccount' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_CONTROL_SERVICE_ACCOUNT="$(jq -r '.controlServiceAccount' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_PRIVATE_ZONE_NAME="$(jq -r '.privateZoneName' "${SHARED_DIR}/xpn.json")"

  if [[ -v GOOGLE_CLOUD_XPN_SA ]]; then
    echo "Using XPN configurations..."
    PROJECT_OPTION="${PROJECT_OPTION} --account ${GOOGLE_CLOUD_XPN_SA}"
  fi
fi

## Create the VPC
echo "$(date -u --rfc-3339=seconds) - Creating the VPC..."
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN VPC..."
  CLUSTER_NETWORK="${HOST_PROJECT_NETWORK}"
  COMPUTE_SUBNET="${HOST_PROJECT_COMPUTE_SUBNET}"
  CONTROL_SUBNET="${HOST_PROJECT_CONTROL_SUBNET}"
elif [[ -f "${SHARED_DIR}/customer_vpc_subnets.yaml" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-configured custom VPC..."
  CLUSTER_NETWORK="$(gcloud compute networks describe "${CLUSTER_NAME}-network" --format json | jq -r .selfLink)"
  CONTROL_SUBNET="$(gcloud compute networks subnets describe "${CLUSTER_NAME}-master-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
  COMPUTE_SUBNET="$(gcloud compute networks subnets describe "${CLUSTER_NAME}-worker-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
else
  create_vpc "${MASTER_SUBNET_CIDR}" "${WORKER_SUBNET_CIDR}"
  short_wait 3

  ## Configure VPC variables
  CLUSTER_NETWORK="$(gcloud compute networks describe "${INFRA_ID}-network" --format json | jq -r .selfLink)"
  CONTROL_SUBNET="$(gcloud compute networks subnets describe "${INFRA_ID}-master-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
  COMPUTE_SUBNET="$(gcloud compute networks subnets describe "${INFRA_ID}-worker-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
fi

function create_external_lb()
{
  local CMD cmd_ret=0

  CMD="gcloud infra-manager deployments apply ${CLUSTER_NAME}-${UPI_RESOURCE_DIR_INFRA_EXTERNAL_LB//_/-} --location=${REGION} --input-values=infra_id=${INFRA_ID},project=${PROJECT_NAME},region=${REGION} --project=${PROJECT_NAME} --service-account=${INSTALL_SERVICE_ACCOUNT}"
  CMD="${CMD} ${SOURCE_OPTIONS}/${UPI_RESOURCE_DIR_INFRA_EXTERNAL_LB}"
  run_command "${CMD}" || cmd_ret=$?
  if [ $cmd_ret -ne 0 ]; then
    infra_manager_debug "${CLUSTER_NAME}-${UPI_RESOURCE_DIR_INFRA_EXTERNAL_LB//_/-}" "${REGION}" $cmd_ret
  fi
  short_wait
}

function create_internal_lb()
{
  local -r cluster_network="$1"; shift
  local -r control_subnet="$1"; shift
  local -r zone_0="$1"; shift
  local -r zone_1="$1"; shift
  local -r zone_2="$1"; shift
  local CMD cmd_ret=0

  CMD="gcloud infra-manager deployments apply ${CLUSTER_NAME}-${UPI_RESOURCE_DIR_INFRA_INTERNAL_LB//_/-} --location=${REGION} --input-values=infra_id=${INFRA_ID},project=${PROJECT_NAME},region=${REGION},cluster_network=${cluster_network},control_subnet=${control_subnet},zone_0=${zone_0},zone_1=${zone_1},zone_2=${zone_2} --project=${PROJECT_NAME} --service-account=${INSTALL_SERVICE_ACCOUNT}"
  CMD="${CMD} ${SOURCE_OPTIONS}/${UPI_RESOURCE_DIR_INFRA_INTERNAL_LB}"
  run_command "${CMD}" || cmd_ret=$?
  if [ $cmd_ret -ne 0 ]; then
    infra_manager_debug "${CLUSTER_NAME}-${UPI_RESOURCE_DIR_INFRA_INTERNAL_LB//_/-}" "${REGION}" $cmd_ret
  fi
  short_wait
}

function create_dns_private_zone()
{
  local -r cluster_domain="$1"; shift
  local -r cluster_network="$1"; shift
  local CMD cmd_ret=0

  CMD="gcloud infra-manager deployments apply ${CLUSTER_NAME}-${UPI_RESOURCE_DIR_INFRA_DNS_PRIV_ZONE//_/-} --location=${REGION} --input-values=infra_id=${INFRA_ID},project=${PROJECT_NAME},region=${REGION},cluster_domain=${cluster_domain},cluster_network=${cluster_network} --project=${PROJECT_NAME} --service-account=${INSTALL_SERVICE_ACCOUNT}"
  CMD="${CMD} ${SOURCE_OPTIONS}/${UPI_RESOURCE_DIR_INFRA_DNS_PRIV_ZONE}"
  run_command "${CMD}" || cmd_ret=$?
  if [ $cmd_ret -ne 0 ]; then
    infra_manager_debug "${CLUSTER_NAME}-${UPI_RESOURCE_DIR_INFRA_DNS_PRIV_ZONE//_/-}" "${REGION}" $cmd_ret
  fi
}

## Create DNS entries and load balancers
echo "$(date -u --rfc-3339=seconds) - Creating load balancers and DNS zone..."
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN private zone..."
  PRIVATE_ZONE_NAME="${HOST_PROJECT_PRIVATE_ZONE_NAME}"
else
  PRIVATE_ZONE_NAME="${INFRA_ID}-private-zone"
  create_dns_private_zone "${CLUSTER_NAME}.${BASE_DOMAIN}" "${CLUSTER_NETWORK}"
fi

echo "$(date -u --rfc-3339=seconds) - Creating internal load balancer resources..."
create_internal_lb "${CLUSTER_NETWORK}" "${CONTROL_SUBNET}" "${ZONE_0}" "${ZONE_1}" "${ZONE_2}"
if [[ "${PUBLISH}" == "Internal" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Publish is '${PUBLISH}', so deploying a private cluster..."
else
  echo "$(date -u --rfc-3339=seconds) - Creating external load balancer resources..."
  create_external_lb
fi

## Configure infra variables
CLUSTER_IP="$(gcloud compute addresses describe "${INFRA_ID}-cluster-ip" "--region=${REGION}" --format json | jq -r .address)"
if [[ "${PUBLISH}" != "Internal" ]]; then
  CLUSTER_PUBLIC_IP="$(gcloud compute addresses describe "${INFRA_ID}-cluster-public-ip" "--region=${REGION}" --format json | jq -r .address)"
fi

API_INTERNAL_BACKEND_SVC=$(gcloud compute backend-services list --filter="name~${INFRA_ID}-api-internal" --format='value(name)')
echo "[DEBUG] API internal backend-service: '${API_INTERNAL_BACKEND_SVC}'"

### Add internal DNS entries
echo "$(date -u --rfc-3339=seconds) - Adding internal DNS entries..."
if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud ${PROJECT_OPTION} dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
gcloud ${PROJECT_OPTION} dns record-sets transaction add "${CLUSTER_IP}" --name "api.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${PROJECT_OPTION} dns record-sets transaction add "${CLUSTER_IP}" --name "api-int.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${PROJECT_OPTION} dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"

### Add external DNS entries (optional)
if [[ "${PUBLISH}" != "Internal" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Adding external DNS entries..."
  if [ -f transaction.yaml ]; then rm transaction.yaml; fi
  gcloud dns record-sets transaction start --zone "${BASE_DOMAIN_ZONE_NAME}"
  gcloud dns record-sets transaction add "${CLUSTER_PUBLIC_IP}" --name "api.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${BASE_DOMAIN_ZONE_NAME}"
  gcloud dns record-sets transaction execute --zone "${BASE_DOMAIN_ZONE_NAME}"
fi

function create_firewall_rules_and_iam_sa()
{
  local -r cluster_network="$1"; shift
  local -r network_cidr="$1"; shift
  local -r allowed_external_cidr="$1"; shift
  local CMD cmd_ret=0

  CMD="gcloud infra-manager deployments apply ${CLUSTER_NAME}-${UPI_RESOURCE_DIR_SECURITY//_/-} --location=${REGION} --input-values=infra_id=${INFRA_ID},project=${PROJECT_NAME},region=${REGION},cluster_network=${cluster_network},network_cidr=${network_cidr},allowed_external_cidr=${allowed_external_cidr} --project=${PROJECT_NAME} --service-account=${INSTALL_SERVICE_ACCOUNT}"
  CMD="${CMD} ${SOURCE_OPTIONS}/${UPI_RESOURCE_DIR_SECURITY}"
  run_command "${CMD}" || cmd_ret=$?
  if [ $cmd_ret -ne 0 ]; then
    infra_manager_debug "${CLUSTER_NAME}-${UPI_RESOURCE_DIR_SECURITY//_/-}" "${REGION}" $cmd_ret
  fi
  short_wait
}

## Create firewall rules and IAM roles
echo "$(date -u --rfc-3339=seconds) - Creating service accounts and firewall rules..."
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN firewall rules..."
  echo "$(date -u --rfc-3339=seconds) - using pre-existing XPN service accounts..."
  MASTER_SERVICE_ACCOUNT="${HOST_PROJECT_CONTROL_SERVICE_ACCOUNT}"
  WORKER_SERVICE_ACCOUNT="${HOST_PROJECT_COMPUTE_SERVICE_ACCOUNT}"
else
  create_firewall_rules_and_iam_sa "${CLUSTER_NETWORK}" "${NETWORK_CIDR}" "0.0.0.0/0"

  ## Configure security variables
  MASTER_SERVICE_ACCOUNT="$(gcloud iam service-accounts list --filter "email~^${INFRA_ID}-m@${PROJECT_NAME}." --format json | jq -r '.[0].email')"
  WORKER_SERVICE_ACCOUNT="$(gcloud iam service-accounts list --filter "email~^${INFRA_ID}-w@${PROJECT_NAME}." --format json | jq -r '.[0].email')"

  ## Add required roles to IAM service accounts
  echo "$(date -u --rfc-3339=seconds) - Adding required roles to IAM service accounts..."
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${MASTER_SERVICE_ACCOUNT}" --role "roles/compute.instanceAdmin" 1> /dev/null
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${MASTER_SERVICE_ACCOUNT}" --role "roles/compute.networkAdmin" 1> /dev/null
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${MASTER_SERVICE_ACCOUNT}" --role "roles/compute.securityAdmin" 1> /dev/null
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${MASTER_SERVICE_ACCOUNT}" --role "roles/iam.serviceAccountUser" 1> /dev/null
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${MASTER_SERVICE_ACCOUNT}" --role "roles/storage.admin" 1> /dev/null

  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${WORKER_SERVICE_ACCOUNT}" --role "roles/compute.viewer" 1> /dev/null
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${WORKER_SERVICE_ACCOUNT}" --role "roles/storage.admin" 1> /dev/null
fi

## Create the cluster image.
echo "$(date -u --rfc-3339=seconds) - Creating the cluster image..."
imagename="${INFRA_ID}-rhcos-image"
# https://github.com/openshift/installer/blob/master/docs/user/overview.md#coreos-bootimages
# This code needs to handle pre-4.8 installers though too.
if openshift-install coreos print-stream-json 2>/tmp/err.txt >coreos.json; then
  jq '.architectures.'"$(echo "$OCP_ARCH" | sed 's/amd64/x86_64/;s/arm64/aarch64/')"'.images.gcp' < coreos.json > gcp.json
  source_image="$(jq -r .name < gcp.json)"
  source_project="$(jq -r .project < gcp.json)"
  rm -f coreos.json gcp.json
  echo "Creating image from ${source_image} in ${source_project}"
  gcloud compute images create "${imagename}" --source-image="${source_image}" --source-image-project="${source_project}"
else
  IMAGE_SOURCE="$(jq -r .gcp.url /var/lib/openshift-install/rhcos.json)"
  gcloud compute images create "${imagename}" --source-uri="${IMAGE_SOURCE}"
fi
CLUSTER_IMAGE="$(gcloud compute images describe "${imagename}" --format json | jq -r .selfLink)"
echo "Using CLUSTER_IMAGE=${CLUSTER_IMAGE}"

## Upload the bootstrap.ign to a new bucket
echo "$(date -u --rfc-3339=seconds) - Uploading the bootstrap.ign to a new bucket..."
gcloud storage buckets create "gs://${INFRA_ID}-bootstrap-ignition"
gcloud storage cp bootstrap.ign "gs://${INFRA_ID}-bootstrap-ignition/"
gcloud storage ls "gs://${INFRA_ID}-bootstrap-ignition/bootstrap.ign"

## Generate a service-account-key for signing the bootstrap.ign url
CMD="gcloud iam service-accounts keys create service-account-key.json --iam-account=${MASTER_SERVICE_ACCOUNT}"
run_command "${CMD}"
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Save the key id for final deletion (XPN scenario)..."
  private_key_id=$(jq -r .private_key_id service-account-key.json)
  echo "${private_key_id}" > "${SHARED_DIR}/xpn_sa_key_id"
fi

BOOTSTRAP_IGN="$(gcloud storage sign-url --duration=1h --private-key-file=service-account-key.json "gs://${INFRA_ID}-bootstrap-ignition/bootstrap.ign" | grep "^signed_url:" | awk '{print $2}')"

function create_bootstrap_resources()
{
  local -r zone="$1"; shift
  local -r cluster_network="$1"; shift
  local -r machine_subnet="$1"; shift
  local -r cluster_image="$1"; shift
  local -r machine_type="$1"; shift
  local -r root_volume_size="$1"; shift
  local -r ignition="$1"; shift
  local -r publish_policy="$1"; shift
  local CMD boolean_publish_policy cmd_ret=0

  # It will be a public cluster by default, i.e. "publish: External". 
  boolean_publish_policy=true
  if [[ "${publish_policy}" == "Internal" ]]; then
    echo "$(date -u --rfc-3339=seconds) - INFO: It will be a private cluster, i.e. \"publish: Internal\"."
    boolean_publish_policy=false
  fi

  CMD="gcloud infra-manager deployments apply ${CLUSTER_NAME}-${UPI_RESOURCE_DIR_BOOTSTRAP//_/-} --location=${REGION} --input-values=infra_id=${INFRA_ID},project=${PROJECT_NAME},region=${REGION},zone=${zone},cluster_network='${cluster_network}',subnet='${machine_subnet}',image='${cluster_image}',machine_type=${machine_type},root_volume_size=${root_volume_size},bootstrap_ign='${ignition}',is_public_cluster=${boolean_publish_policy} --project=${PROJECT_NAME} --service-account=${INSTALL_SERVICE_ACCOUNT}"
  CMD="${CMD} ${SOURCE_OPTIONS}/${UPI_RESOURCE_DIR_BOOTSTRAP}"
  run_command "${CMD}" || cmd_ret=$?
  if [ $cmd_ret -ne 0 ]; then
    infra_manager_debug "${CLUSTER_NAME}-${UPI_RESOURCE_DIR_BOOTSTRAP//_/-}" "${REGION}" $cmd_ret
  fi
  short_wait
}

## Launch temporary bootstrap resources
echo "$(date -u --rfc-3339=seconds) - Launching temporary bootstrap resources..."
ls -l "bootstrap.ign"
create_bootstrap_resources "${ZONE_0}" "${CLUSTER_NETWORK}" "${CONTROL_SUBNET}" "${CLUSTER_IMAGE}" "${BOOTSTRAP_NODE_TYPE}" "128" "${BOOTSTRAP_IGN}" "${PUBLISH}"
BOOTSTRAP_INSTANCE_GROUP=$(gcloud compute instance-groups list --filter="name~^${INFRA_ID}-bootstrap-" --format "value(name)")
## Add the bootstrap instance to the load balancers
echo "$(date -u --rfc-3339=seconds) - Adding the bootstrap instance to the load balancers..."
cmd="gcloud compute instance-groups unmanaged add-instances ${BOOTSTRAP_INSTANCE_GROUP} --zone=${ZONE_0} --instances=${INFRA_ID}-bootstrap"
run_command "${cmd}"
cmd="gcloud compute backend-services add-backend ${API_INTERNAL_BACKEND_SVC} --region=${REGION} --instance-group=${BOOTSTRAP_INSTANCE_GROUP} --instance-group-zone=${ZONE_0}"
run_command "${cmd}"

if [[ "${PUBLISH}" != "Internal" ]]; then
  cmd="gcloud compute target-pools add-instances ${INFRA_ID}-api-target-pool --instances-zone=${ZONE_0} --instances=${INFRA_ID}-bootstrap"
  run_command "${cmd}"

  BOOTSTRAP_IP="$(gcloud compute addresses describe --region "${REGION}" "${INFRA_ID}-bootstrap-public-ip" --format json | jq -r .address)"
else
  BOOTSTRAP_IP="$(gcloud compute instances describe --zone "${ZONE_0}" "${INFRA_ID}-bootstrap" --format=json | jq -r .networkInterfaces[].networkIP)"
fi
GATHER_BOOTSTRAP_ARGS=('--bootstrap' "${BOOTSTRAP_IP}")

# debugging purpose
cmd="gcloud compute instances list --filter=\"name~${INFRA_ID}\""
run_command "${cmd}"
cmd="gcloud compute addresses list --filter=\"name~${INFRA_ID}\""
run_command "${cmd}"

function create_control_plane_machines()
{
  local -r machine_subnet="$1"; shift
  local -r cluster_image="$1"; shift
  local -r machine_type="$1"; shift
  local -r root_volume_size="$1"; shift
  local -r service_account="$1"; shift
  local -r zone_0="$1"; shift
  local -r zone_1="$1"; shift
  local -r zone_2="$1"; shift
  local CMD cmd_ret=0

  cp "master.ign" "${GCP_UPI_SOURCE_FILES_DIR}/${UPI_RESOURCE_DIR_CONTROL_PLANE}/"

  CMD="gcloud infra-manager deployments apply ${CLUSTER_NAME}-${UPI_RESOURCE_DIR_CONTROL_PLANE//_/-} --location=${REGION} --input-values=infra_id=${INFRA_ID},project=${PROJECT_NAME},region=${REGION},zone_0=${zone_0},zone_1=${zone_1},zone_2=${zone_2},subnet=${machine_subnet},image=${cluster_image},machine_type=${machine_type},disk_size=${root_volume_size},service_account_email=${service_account} --project=${PROJECT_NAME} --service-account=${INSTALL_SERVICE_ACCOUNT}"
  CMD="${CMD} ${SOURCE_OPTIONS}/${UPI_RESOURCE_DIR_CONTROL_PLANE}"
  run_command "${CMD}" || cmd_ret=$?
  if [ $cmd_ret -ne 0 ]; then
    infra_manager_debug "${CLUSTER_NAME}-${UPI_RESOURCE_DIR_CONTROL_PLANE//_/-}" "${REGION}" $cmd_ret
  fi
  short_wait

  rm -f "${GCP_UPI_SOURCE_FILES_DIR}/${UPI_RESOURCE_DIR_CONTROL_PLANE}/master.ign"
}

## Launch permanent control plane
echo "$(date -u --rfc-3339=seconds) - Launching permanent control plane..."
create_control_plane_machines "${CONTROL_SUBNET}" "${CLUSTER_IMAGE}" "${CONTROL_PLANE_NODE_TYPE}" "128" "${MASTER_SERVICE_ACCOUNT}" "${ZONE_0}" "${ZONE_1}" "${ZONE_2}"

## Configure control plane variables
MASTER0_IP="$(gcloud compute instances describe "${INFRA_ID}-master-0" --zone "${ZONE_0}" --format json | jq -r .networkInterfaces[0].networkIP)"
MASTER1_IP="$(gcloud compute instances describe "${INFRA_ID}-master-1" --zone "${ZONE_1}" --format json | jq -r .networkInterfaces[0].networkIP)"
MASTER2_IP="$(gcloud compute instances describe "${INFRA_ID}-master-2" --zone "${ZONE_2}" --format json | jq -r .networkInterfaces[0].networkIP)"

GATHER_BOOTSTRAP_ARGS+=('--master' "${MASTER0_IP}" '--master' "${MASTER1_IP}" '--master' "${MASTER2_IP}")

## Add DNS entries for control plane etcd
echo "$(date -u --rfc-3339=seconds) - Adding DNS entries for control plane etcd..."
if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud ${PROJECT_OPTION} dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
gcloud ${PROJECT_OPTION} dns record-sets transaction add "${MASTER0_IP}" --name "etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${PROJECT_OPTION} dns record-sets transaction add "${MASTER1_IP}" --name "etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${PROJECT_OPTION} dns record-sets transaction add "${MASTER2_IP}" --name "etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${PROJECT_OPTION} dns record-sets transaction add \
  "0 10 2380 etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  "0 10 2380 etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  "0 10 2380 etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  --name "_etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type SRV --zone "${PRIVATE_ZONE_NAME}"
gcloud ${PROJECT_OPTION} dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"

MASTER_IG_0="$(gcloud compute instance-groups list --filter "name~^${INFRA_ID}-master-${ZONE_0}-" --format "value(name)")"
MASTER_IG_1="$(gcloud compute instance-groups list --filter "name~^${INFRA_ID}-master-${ZONE_1}-" --format "value(name)")"
MASTER_IG_2="$(gcloud compute instance-groups list --filter "name~^${INFRA_ID}-master-${ZONE_2}-" --format "value(name)")"
## Add control plane instances to load balancers
echo "$(date -u --rfc-3339=seconds) - Adding control plane instances to instance groups..."
cmd="gcloud compute instance-groups unmanaged add-instances ${MASTER_IG_0} --zone=${ZONE_0} --instances=${INFRA_ID}-master-0"
run_command "${cmd}"
cmd="gcloud compute instance-groups unmanaged add-instances ${MASTER_IG_1} --zone=${ZONE_1} --instances=${INFRA_ID}-master-1"
run_command "${cmd}"
cmd="gcloud compute instance-groups unmanaged add-instances ${MASTER_IG_2} --zone=${ZONE_2} --instances=${INFRA_ID}-master-2"
run_command "${cmd}"

if [[ "${PUBLISH}" != "Internal" ]]; then
  ### Add control plane instances to external load balancer target pools (optional)
  cmd="gcloud compute target-pools add-instances ${INFRA_ID}-api-target-pool --instances-zone=${ZONE_0} --instances=${INFRA_ID}-master-0"
  run_command "${cmd}"
  cmd="gcloud compute target-pools add-instances ${INFRA_ID}-api-target-pool --instances-zone=${ZONE_1} --instances=${INFRA_ID}-master-1"
  run_command "${cmd}"
  cmd="gcloud compute target-pools add-instances ${INFRA_ID}-api-target-pool --instances-zone=${ZONE_2} --instances=${INFRA_ID}-master-2"
  run_command "${cmd}"
fi

function create_worker_machines()
{
  local -r machine_subnet="$1"; shift
  local -r cluster_image="$1"; shift
  local -r machine_type="$1"; shift
  local -r root_volume_size="$1"; shift
  local -r service_account="$1"; shift
  local -r zone_0="$1"; shift
  local -r zone_1="$1"; shift
  local CMD cmd_ret=0


  cp "worker.ign" "${GCP_UPI_SOURCE_FILES_DIR}/${UPI_RESOURCE_DIR_WORKER}/"

  CMD="gcloud infra-manager deployments apply ${CLUSTER_NAME}-${UPI_RESOURCE_DIR_WORKER//_/-} --location=${REGION} --input-values=infra_id=${INFRA_ID},project=${PROJECT_NAME},region=${REGION},zone_0=${zone_0},zone_1=${zone_1},subnet=${machine_subnet},image=${cluster_image},machine_type=${machine_type},disk_size=${root_volume_size},service_account_email=${service_account} --project=${PROJECT_NAME} --service-account=${INSTALL_SERVICE_ACCOUNT}"
  CMD="${CMD} ${SOURCE_OPTIONS}/${UPI_RESOURCE_DIR_WORKER}"
  run_command "${CMD}" || cmd_ret=$?
  if [ $cmd_ret -ne 0 ]; then
    infra_manager_debug "${CLUSTER_NAME}-${UPI_RESOURCE_DIR_WORKER//_/-}" "${REGION}" $cmd_ret
  fi
  short_wait

  rm -f "${GCP_UPI_SOURCE_FILES_DIR}/${UPI_RESOURCE_DIR_WORKER}/worker.ign"
}

## Launch additional compute nodes
echo "$(date -u --rfc-3339=seconds) - Launching additional compute nodes..."
## Available zones and instance zones might be different in region for arm64 machines
mapfile -t WORKER_INSTANCE_ZONES < <(gcloud compute machine-types list --filter="zone:(${REGION}) AND name=(${COMPUTE_NODE_TYPE})" --format=json | jq -r '.[].zone')
mapfile -t WORKER_ZONES < <(echo "${AVAILABILITY_ZONES[@]}" "${WORKER_INSTANCE_ZONES[@]}" | sed 's/ /\n/g' | sort -R | uniq -d)
create_worker_machines "${COMPUTE_SUBNET}" "${CLUSTER_IMAGE}" "${COMPUTE_NODE_TYPE}" "128" "${WORKER_SERVICE_ACCOUNT}" "${WORKER_ZONES[(( 0 % ${#WORKER_ZONES[@]} ))]}" "${WORKER_ZONES[(( 1 % ${#WORKER_ZONES[@]} ))]}"

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    echo "$(date -u --rfc-3339=seconds) - Enabling proxy settings..."
    source "${SHARED_DIR}/proxy-conf.sh"
fi

## Monitor for `bootstrap-complete`
echo "$(date -u --rfc-3339=seconds) - Monitoring for bootstrap to complete"
openshift-install --dir="${dir}" wait-for bootstrap-complete &

set +e
wait "$!"
ret="$?"
set -e

if [ "$ret" -ne 0 ]; then
  set +e
  # Attempt to gather bootstrap logs.
  echo "$(date -u --rfc-3339=seconds) - Bootstrap failed, attempting to gather bootstrap logs..."
  openshift-install "--dir=${dir}" gather bootstrap --key "${SSH_PRIV_KEY_PATH}" "${GATHER_BOOTSTRAP_ARGS[@]}"
  sed 's/password: .*/password: REDACTED/' "${dir}/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"
  cp log-bundle-*.tar.gz "${ARTIFACT_DIR}"
  set -e
  exit "$ret"
fi

## Destroy bootstrap resources
echo "$(date -u --rfc-3339=seconds) - Bootstrap complete, destroying bootstrap resources"
cmd="gcloud compute backend-services remove-backend ${API_INTERNAL_BACKEND_SVC} --region=${REGION} --instance-group=${BOOTSTRAP_INSTANCE_GROUP} --instance-group-zone=${ZONE_0}"
run_command "${cmd}"
if [[ "${PUBLISH}" != "Internal" ]]; then # for workflow using internal load balancers
  cmd="gcloud compute target-pools remove-instances ${INFRA_ID}-api-target-pool --instances-zone=${ZONE_0} --instances=${INFRA_ID}-bootstrap"
  run_command "${cmd}"
fi
# remove from the backend service of random id
backend_service_random_id=$(gcloud compute backend-services list --format=json --filter="backends[].group~${INFRA_ID}" | jq -r .[].name | grep -v "${INFRA_ID}" || echo "")
echo "[DEBUG] the backend service of random id: '${backend_service_random_id}'"
if [[ -n "${backend_service_random_id}" ]]; then
  echo "[DEBUG] Running Command: 'gcloud compute backend-services describe ${backend_service_random_id} --region ${REGION} --format json | jq -r .backends | grep \"${BOOTSTRAP_INSTANCE_GROUP}\"'"
  if gcloud compute backend-services describe ${backend_service_random_id} --region ${REGION} --format json | jq -r .backends | grep "${BOOTSTRAP_INSTANCE_GROUP}"; then
    cmd="gcloud compute backend-services remove-backend ${backend_service_random_id} --region=${REGION} --instance-group=${BOOTSTRAP_INSTANCE_GROUP} --instance-group-zone=${ZONE_0}"
    run_command "${cmd}"
  else
    echo "[DEBUG] ${BOOTSTRAP_INSTANCE_GROUP} is not in ${backend_service_random_id} backends."
  fi
fi

gcloud storage rm "gs://${INFRA_ID}-bootstrap-ignition/bootstrap.ign"
gcloud storage buckets delete "gs://${INFRA_ID}-bootstrap-ignition"
CMD="gcloud infra-manager deployments delete -q ${CLUSTER_NAME}-${UPI_RESOURCE_DIR_BOOTSTRAP//_/-} --location=${REGION}"
run_command "${CMD}"
short_wait

## Approving the CSR requests for nodes
echo "$(date -u --rfc-3339=seconds) - Approving the CSR requests for nodes..."
function approve_csrs() {
  while [[ ! -f /tmp/install-complete ]]; do
      # even if oc get csr fails continue
      oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      short_wait 15 & wait
  done
}
approve_csrs &

## Wait for the default-router to have an external ip...(and not <pending>)
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Waiting for the default-router to have an external ip..."
  set +e
  ROUTER_IP="$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')"
  while [[ "$ROUTER_IP" == "" || "$ROUTER_IP" == "<pending>" ]]; do
    short_wait 10;
    ROUTER_IP="$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')"
  done
  set -e
fi

## Create default router dns entries
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Creating default router DNS entries..."
  if [ -f transaction.yaml ]; then rm transaction.yaml; fi
  gcloud ${PROJECT_OPTION} dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
  gcloud ${PROJECT_OPTION} dns record-sets transaction add "${ROUTER_IP}" --name "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 300 --type A --zone "${PRIVATE_ZONE_NAME}"
  gcloud ${PROJECT_OPTION} dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"

  if [[ "${PUBLISH}" != "Internal" ]]; then
    if [ -f transaction.yaml ]; then rm transaction.yaml; fi
    gcloud dns record-sets transaction start --zone "${BASE_DOMAIN_ZONE_NAME}"
    gcloud dns record-sets transaction add "${ROUTER_IP}" --name "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 300 --type A --zone "${BASE_DOMAIN_ZONE_NAME}"
    gcloud dns record-sets transaction execute --zone "${BASE_DOMAIN_ZONE_NAME}"
  fi
fi

## Monitor for cluster completion
echo "$(date -u --rfc-3339=seconds) - Monitoring for cluster completion..."
openshift-install --dir="${dir}" wait-for install-complete 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &

set +e
wait "$!"
ret="$?"
set -e

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

sed 's/password: .*/password: REDACTED/' "${dir}/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"

if [ $ret -ne 0 ]; then
  exit "$ret"
fi

cp -t "${SHARED_DIR}" \
    "${dir}/auth/kubeconfig"

popd
touch /tmp/install-complete
