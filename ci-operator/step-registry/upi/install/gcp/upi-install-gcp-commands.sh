#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

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

function run_command() {
  local CMD="$1"
  echo "$(date -u --rfc-3339=seconds) - Running command: ${CMD}"
  eval "${CMD}"
}

# resources deprovision script filename
# FYI the create_X function will populate the deprovision script file
VPC_DEPROVISION_SCRIPTS="${SHARED_DIR}/01_vpc_deprovision.sh"
EXTERNAL_LB_DEPROVISION_SCRIPTS="${SHARED_DIR}/02_external_lb_deprovision.sh"
INTERNAL_LB_DEPROVISION_SCRIPTS="${SHARED_DIR}/02_internal_lb_deprovision.sh"
DNS_PRIV_ZONE_DEPROVISION_SCRIPTS="${SHARED_DIR}/02_dns_priv_zone_deprovision.sh"
FIREWALL_RULES_DEPROVISION_SCRIPTS="${SHARED_DIR}/03_firewall_rules_deprovision.sh"
IAM_SA_DEPROVISION_SCRIPTS="${SHARED_DIR}/03_iam_sa_deprovision.sh"
BOOTSTRAP_DEPROVISION_SCRIPTS="${SHARED_DIR}/04_bootstrap_deprovision.sh"
CONTROL_PLANE_DEPROVISION_SCRIPTS="${SHARED_DIR}/05_control_plane_deprovision.sh"
WORKER_DEPROVISION_SCRIPTS="${SHARED_DIR}/06_worker_deprovision.sh"

function create_vpc()
{
  local -r infra_id="$1"; shift
  local -r region="$1"; shift
  local -r subnet1_cidr="$1"; shift
  local -r subnet2_cidr="$1"; shift
  local -r deprovision_commands_file="$1"
  local CMD=""

  # create network
  CMD="gcloud compute networks create ${infra_id}-network --subnet-mode=custom"
  run_command "${CMD}"

  # create subnets
  CMD="gcloud compute networks subnets create ${infra_id}-master-subnet --network=${infra_id}-network --range=${subnet1_cidr} --region=${region}"
  run_command "${CMD}"
  CMD="gcloud compute networks subnets create ${infra_id}-worker-subnet --network=${infra_id}-network --range=${subnet2_cidr} --region=${region}"
  run_command "${CMD}"

  # create router
  CMD="gcloud compute routers create ${infra_id}-router --network=${infra_id}-network --region=${region}"
  run_command "${CMD}"

  # create nats
  CMD="gcloud compute routers nats create ${infra_id}-nat-master --router=${infra_id}-router --auto-allocate-nat-external-ips --nat-custom-subnet-ip-ranges=${infra_id}-master-subnet --region=${region}"
  run_command "${CMD}"
  CMD="gcloud compute routers nats create ${infra_id}-nat-worker --router=${infra_id}-router --auto-allocate-nat-external-ips --nat-custom-subnet-ip-ranges=${infra_id}-worker-subnet --region=${region}"
  run_command "${CMD}"

  # for deprovision
  cat > "${deprovision_commands_file}" << EOF
gcloud compute routers nats delete -q ${infra_id}-nat-master --router ${infra_id}-router --region ${region}
gcloud compute routers nats delete -q ${infra_id}-nat-worker --router ${infra_id}-router --region ${region}
gcloud compute routers delete -q ${infra_id}-router --region ${region}
gcloud compute networks subnets delete -q ${infra_id}-master-subnet --region ${region}
gcloud compute networks subnets delete -q ${infra_id}-worker-subnet --region ${region}
gcloud compute networks delete -q ${infra_id}-network
EOF
}

echo "$(date -u --rfc-3339=seconds) - Configuring gcloud..."
if version_check "4.11"; then
  GCLOUD_SDK_VERSION="447"
else
  GCLOUD_SDK_VERSION="256"
fi
if ! gcloud --version; then
  GCLOUD_TAR="google-cloud-sdk-${GCLOUD_SDK_VERSION}.0.0-linux-x86_64.tar.gz"
  GCLOUD_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$GCLOUD_TAR"
  echo "$(date -u --rfc-3339=seconds) - gcloud not installed: installing from $GCLOUD_URL"
  pushd ${HOME}
  curl -O "$GCLOUD_URL"
  tar -xzf "$GCLOUD_TAR"
  export PATH=${HOME}/google-cloud-sdk/bin:${PATH}
  popd
fi
gcloud version

if [[ -s "${SHARED_DIR}/xpn.json" ]] && [[ -f "${CLUSTER_PROFILE_DIR}/xpn_creds.json" ]]; then
  echo "Activating XPN service-account..."
  GOOGLE_CLOUD_XPN_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/xpn_creds.json"
  gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_XPN_KEYFILE_JSON}"
  GOOGLE_CLOUD_XPN_SA=$(jq -r .client_email "${GOOGLE_CLOUD_XPN_KEYFILE_JSON}")
fi
export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"
gcloud config set project "$(jq -r .gcp.projectID "${SHARED_DIR}/metadata.json")"

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
cp -t "${dir}" \
    "/var/lib/openshift-install/upi/${CLUSTER_TYPE}"/*
tar -xzf "${SHARED_DIR}/.openshift_install_state.json.tgz"

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

MASTER_IGNITION="$(cat master.ign)"
WORKER_IGNITION="$(cat worker.ign)"

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
  create_vpc "${INFRA_ID}" "${REGION}" "${MASTER_SUBNET_CIDR}" "${WORKER_SUBNET_CIDR}" "${VPC_DEPROVISION_SCRIPTS}"
  short_wait 3

  ## Configure VPC variables
  CLUSTER_NETWORK="$(gcloud compute networks describe "${INFRA_ID}-network" --format json | jq -r .selfLink)"
  CONTROL_SUBNET="$(gcloud compute networks subnets describe "${INFRA_ID}-master-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
  COMPUTE_SUBNET="$(gcloud compute networks subnets describe "${INFRA_ID}-worker-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
fi

function create_external_lb()
{
  local -r infra_id="$1"; shift
  local -r region="$1"; shift
  local -r deprovision_commands_file="$1"
  local CMD address_selflink hc_selflink tp_selflink

  # create address
  CMD="gcloud compute addresses create ${infra_id}-cluster-public-ip --region=${region}"
  run_command "${CMD}"
  short_wait
  address_selflink=$(gcloud compute addresses describe ${infra_id}-cluster-public-ip --region=${region} --format=json | jq -r .selfLink)

  # create http-health-check
  CMD="gcloud compute http-health-checks create ${infra_id}-api-http-health-check --port=6080 --request-path=\"/readyz\""
  run_command "${CMD}"
  short_wait
  hc_selflink=$(gcloud compute http-health-checks describe ${infra_id}-api-http-health-check --format=json | jq -r .selfLink)

  # create target-pool
  CMD="gcloud compute target-pools create ${infra_id}-api-target-pool --http-health-check=${hc_selflink} --region=${region}"
  run_command "${CMD}"
  short_wait
  tp_selflink=$(gcloud compute target-pools describe ${infra_id}-api-target-pool --region=${region} --format=json | jq -r .selfLink)

  # create forwarding-rule
  CMD="gcloud compute forwarding-rules create ${infra_id}-api-forwarding-rule --region=${region} --address=${address_selflink} --target-pool=${tp_selflink} --port-range=6443"
  run_command "${CMD}"
  short_wait

  # for deprovision
  cat > "${deprovision_commands_file}" << EOF
gcloud compute forwarding-rules delete -q ${infra_id}-api-forwarding-rule --region=${region}
gcloud compute target-pools delete -q ${infra_id}-api-target-pool --region=${region}
gcloud compute http-health-checks delete -q ${infra_id}-api-http-health-check
gcloud compute addresses delete -q ${infra_id}-cluster-public-ip --region=${region}
EOF
}

function create_internal_lb()
{
  local -r infra_id="$1"; shift
  local -r region="$1"; shift
  local -r control_subnet="$1"; shift
  local -r deprovision_commands_file="$1"; shift
  local -r zones=("$@")
  local CMD address_selflink hc_selflink bs_selflink

  # create internal address
  CMD="gcloud compute addresses create ${infra_id}-cluster-ip --region=${region} --subnet=${control_subnet}"
  run_command "${CMD}"
  short_wait
  address_selflink=$(gcloud compute addresses describe ${infra_id}-cluster-ip --region=${region} --format=json | jq -r .selfLink)

  # create health-check
  CMD="gcloud compute health-checks create https ${infra_id}-api-internal-health-check --port=6443 --request-path=\"/readyz\""
  run_command "${CMD}"
  short_wait
  hc_selflink=$(gcloud compute health-checks describe ${infra_id}-api-internal-health-check --format=json | jq -r .selfLink)

  # create backend-service
  CMD="gcloud compute backend-services create ${infra_id}-api-internal --region=${region} --protocol=TCP --load-balancing-scheme=INTERNAL --health-checks=${hc_selflink} --timeout=120"
  run_command "${CMD}"
  short_wait
  bs_selflink=$(gcloud compute backend-services describe ${infra_id}-api-internal --region=${region} --format=json | jq -r .selfLink)

  # create instance-groups
  for zone in "${zones[@]}"; do
    CMD="gcloud compute instance-groups unmanaged create ${infra_id}-master-${zone}-ig --zone=${zone}"
    run_command "${CMD}"
    short_wait
    CMD="gcloud compute instance-groups unmanaged set-named-ports ${infra_id}-master-${zone}-ig --zone=${zone} --named-ports=ignition:22623,https:6443"
    run_command "${CMD}"
    short_wait
    #CMD="gcloud compute backend-services add-backend ${infra_id}-api-internal --region=${region} --instance-group=${infra_id}-master-${zone}-ig --instance-group-zone=${zone}"
    #run_command "${CMD}"
  done

  # create forwarding-rule
  CMD="gcloud compute forwarding-rules create ${infra_id}-api-internal-forwarding-rule --region=${region} --load-balancing-scheme=INTERNAL --ports=6443,22623 --backend-service=${bs_selflink} --address=${address_selflink} --subnet=${control_subnet}"
  run_command "${CMD}"
  short_wait

  # for deprovision
  cat > "${deprovision_commands_file}" << EOF
gcloud compute forwarding-rules delete -q ${infra_id}-api-internal-forwarding-rule --region=${region}
gcloud compute backend-services delete -q ${infra_id}-api-internal --region=${region}
gcloud compute health-checks delete -q https ${infra_id}-api-internal-health-check
gcloud compute addresses delete -q ${infra_id}-cluster-ip --region=${region}
EOF
  for zone in "${zones[@]}"; do
    cat >> "${deprovision_commands_file}" << EOF
gcloud compute instance-groups unmanaged delete -q ${infra_id}-master-${zone}-ig --zone=${zone}
EOF
  done
}

function create_dns_private_zone()
{
  local -r infra_id="$1"; shift
  local -r cluster_domain="$1"; shift
  local -r cluster_network="$1"; shift
  local -r deprovision_commands_file="$1"
  local CMD

  CMD="gcloud dns managed-zones create ${infra_id}-private-zone --dns-name=${cluster_domain}. --visibility=private --networks=${cluster_network} --description=${infra_id}-private-zone"
  run_command "${CMD}"
  short_wait

  # for deprovision
  cat > "${deprovision_commands_file}" << EOF
gcloud dns managed-zones delete -q ${infra_id}-private-zone
EOF
}

## Create DNS entries and load balancers
echo "$(date -u --rfc-3339=seconds) - Creating load balancers and DNS zone..."
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN private zone..."
  PRIVATE_ZONE_NAME="${HOST_PROJECT_PRIVATE_ZONE_NAME}"
else
  PRIVATE_ZONE_NAME="${INFRA_ID}-private-zone"
  create_dns_private_zone "${INFRA_ID}" "${CLUSTER_NAME}.${BASE_DOMAIN}" "${CLUSTER_NETWORK}" "${DNS_PRIV_ZONE_DEPROVISION_SCRIPTS}"
fi

echo "$(date -u --rfc-3339=seconds) - Creating internal load balancer resources..."
create_internal_lb "${INFRA_ID}" "${REGION}" "${CONTROL_SUBNET}" "${INTERNAL_LB_DEPROVISION_SCRIPTS}" "${ZONE_0}" "${ZONE_1}" "${ZONE_2}"
if [[ "${PUBLISH}" == "Internal" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Publish is '${PUBLISH}', so deploying a private cluster..."
else
  echo "$(date -u --rfc-3339=seconds) - Creating external load balancer resources..."
  create_external_lb "${INFRA_ID}" "${REGION}" "${EXTERNAL_LB_DEPROVISION_SCRIPTS}"
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

function create_iam_sa()
{
  local -r infra_id="$1"; shift
  local -r deprovision_commands_file="$1"
  local CMD sa1_email sa2_email

  CMD="gcloud iam service-accounts create ${infra_id}-m --display-name=${infra_id}-master-node"
  run_command "${CMD}"
  short_wait
  sa1_email=$(gcloud iam service-accounts list --filter='email~${infra_id}-m' --format='value(email)')

  CMD="gcloud iam service-accounts create ${infra_id}-w --display-name=${infra_id}-worker-node"
  run_command "${CMD}"
  short_wait
  sa2_email=$(gcloud iam service-accounts list --filter='email~${infra_id}-w' --format='value(email)')

  # for deprovision
  cat > "${deprovision_commands_file}" << EOF
gcloud iam service-accounts delete -q ${sa1_email}
gcloud iam service-accounts delete -q ${sa2_email}
EOF
}

function create_firewall_rules()
{
  local -r infra_id="$1"; shift
  local -r cluster_network="$1"; shift
  local -r network_cidr="$1"; shift
  local -r allowed_external_cidr="$1"; shift
  local -r deprovision_commands_file="$1"
  local CMD

  CMD="gcloud compute firewall-rules create ${infra_id}-bootstrap-in-ssh --network=${cluster_network} --allow=tcp:22 --source-ranges=${allowed_external_cidr} --target-tags=${infra_id}-bootstrap"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-api --network=${cluster_network} --allow=tcp:6443 --source-ranges=${allowed_external_cidr} --target-tags=${infra_id}-master"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-health-checks --network=${cluster_network} --allow=tcp:6080,tcp:6443,tcp:22624 --source-ranges=35.191.0.0/16,130.211.0.0/22,209.85.152.0/22,209.85.204.0/22 --target-tags=${infra_id}-master"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-etcd --network=${cluster_network} --allow=tcp:2379-2380 --source-tags=${infra_id}-master --target-tags=${infra_id}-master"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-control-plane --network=${cluster_network} --allow=tcp:10257,tcp:10259,tcp:22623 --source-tags=${infra_id}-master,${infra_id}-worker --target-tags=${infra_id}-master"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-internal-network --network=${cluster_network} --allow=icmp,tcp:22 --source-ranges=${network_cidr} --target-tags=${infra_id}-master,${infra_id}-worker"
  run_command "${CMD}"

  CMD="gcloud compute firewall-rules create ${infra_id}-internal-cluster --network=${cluster_network} --allow=udp:4789,udp:6081,udp:500,udp:4500,esp,tcp:9000-9999,udp:9000-9999,tcp:10250,tcp:30000-32767,udp:30000-32767 --source-tags=${infra_id}-master,${infra_id}-worker --target-tags=${infra_id}-master,${infra_id}-worker"
  run_command "${CMD}"

  # for deprovision
  cat > "${deprovision_commands_file}" << EOF
gcloud compute firewall-rules delete -q ${infra_id}-bootstrap-in-ssh ${infra_id}-api ${infra_id}-health-checks ${infra_id}-etcd ${infra_id}-control-plane ${infra_id}-internal-network ${infra_id}-internal-cluster
EOF
}

## Create firewall rules and IAM roles
echo "$(date -u --rfc-3339=seconds) - Creating service accounts and firewall rules..."
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN firewall rules..."
  echo "$(date -u --rfc-3339=seconds) - using pre-existing XPN service accounts..."
  MASTER_SERVICE_ACCOUNT="${HOST_PROJECT_CONTROL_SERVICE_ACCOUNT}"
  WORKER_SERVICE_ACCOUNT="${HOST_PROJECT_COMPUTE_SERVICE_ACCOUNT}"
else
  create_iam_sa "${INFRA_ID}" "${IAM_SA_DEPROVISION_SCRIPTS}"
  create_firewall_rules "${INFRA_ID}" "${CLUSTER_NETWORK}" "${NETWORK_CIDR}" "0.0.0.0/0" "${FIREWALL_RULES_DEPROVISION_SCRIPTS}"

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

## Generate a service-account-key for signing the bootstrap.ign url
gcloud iam service-accounts keys create service-account-key.json "--iam-account=${MASTER_SERVICE_ACCOUNT}"
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Save the key id for final deletion (XPN scenario)..."
  private_key_id=$(jq -r .private_key_id service-account-key.json)
  echo "${private_key_id}" > "${SHARED_DIR}/xpn_sa_key_id"
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
gsutil mb "gs://${INFRA_ID}-bootstrap-ignition"
gsutil cp bootstrap.ign "gs://${INFRA_ID}-bootstrap-ignition/"

BOOTSTRAP_IGN="$(gsutil signurl -d 1h service-account-key.json "gs://${INFRA_ID}-bootstrap-ignition/bootstrap.ign" | grep "^gs:" | awk '{print $5}')"

function create_bootstrap_resources()
{
  local -r infra_id="$1"; shift
  local -r region="$1"; shift
  local -r zone="$1"; shift
  local -r control_subnet="$1"; shift
  local -r cluster_image="$1"; shift
  local -r node_type="$1"; shift
  local -r root_volume_size="$1"; shift
  local -r ignition="$1"; shift
  local -r publish_policy="$1"; shift
  local -r deprovision_commands_file="$1"
  local CMD public_ip

  # create address
  if [[ "${publish_policy}" != "Internal" ]]; then
    CMD="gcloud compute addresses create ${infra_id}-bootstrap-public-ip --region=${region}"
    run_command "${CMD}"
    short_wait
    public_ip=$(gcloud compute addresses describe ${infra_id}-bootstrap-public-ip --region=${region} --format=json | jq -r .address)
  fi

  CMD="gcloud compute instances create ${infra_id}-bootstrap --boot-disk-size=${root_volume_size}GB --image=${cluster_image} --metadata=^#^user-data='{\"ignition\":{\"config\":{\"replace\":{\"source\":\"${ignition}\"}},\"version\":\"3.2.0\"}}' --machine-type=${node_type} --zone=${zone} --tags=${infra_id}-master,${infra_id}-bootstrap --subnet=${control_subnet}"
  if [[ "${publish_policy}" != "Internal" ]]; then
    CMD="${CMD} --address=${public_ip}"
  else
    CMD="${CMD} --no-address"
  fi
  run_command "${CMD}"
  short_wait

  CMD="gcloud compute instance-groups unmanaged create ${infra_id}-bootstrap-ig --zone=${zone}"
  run_command "${CMD}"
  short_wait
  CMD="gcloud compute instance-groups unmanaged set-named-ports ${infra_id}-bootstrap-ig --zone=${zone} --named-ports=ignition:22623,https:6443"
  run_command "${CMD}"
  short_wait

  # for deprovision
  cat > "${deprovision_commands_file}" << EOF
gcloud compute instance-groups unmanaged delete -q ${infra_id}-bootstrap-ig --zone=${zone}
gcloud compute instances delete -q ${infra_id}-bootstrap --zone=${zone}
EOF
  if [[ "${publish_policy}" != "Internal" ]]; then
    cat >> "${deprovision_commands_file}" << EOF
gcloud compute addresses delete -q ${infra_id}-bootstrap-public-ip --region=${region}
EOF
  fi
}

## Launch temporary bootstrap resources
echo "$(date -u --rfc-3339=seconds) - Launching temporary bootstrap resources..."
ls -l "bootstrap.ign"
create_bootstrap_resources "${INFRA_ID}" "${REGION}" "${ZONE_0}" "${CONTROL_SUBNET}" "${CLUSTER_IMAGE}" "${BOOTSTRAP_NODE_TYPE}" "128" "${BOOTSTRAP_IGN}" "${PUBLISH}" "${BOOTSTRAP_DEPROVISION_SCRIPTS}"
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

function create_cluster_machines()
{
  local -r machine_role="$1"; shift
  local -r infra_id="$1"; shift
  local -r machine_subnet="$1"; shift
  local -r cluster_image="$1"; shift
  local -r node_type="$1"; shift
  local -r root_volume_size="$1"; shift
  local -r service_account="$1"; shift
  local -r ignition="$1"; shift
  local -r deprovision_commands_file="$1"; shift
  local -r zones=("$@")
  local CMD index=0

  for zone in "${zones[@]}"; do
    CMD="gcloud compute instances create ${infra_id}-${machine_role}-${index} --boot-disk-size=${root_volume_size}GB --boot-disk-type=pd-ssd --image=${cluster_image} --metadata=^#^user-data='${ignition}' --machine-type=${node_type} --zone=${zone} --no-address --service-account=${service_account} --scopes=https://www.googleapis.com/auth/cloud-platform --tags=${infra_id}-${machine_role} --subnet=${machine_subnet}"
    run_command "${CMD}"
    short_wait

  # for deprovision
  cat >> "${deprovision_commands_file}" << EOF
gcloud compute instances delete -q ${infra_id}-${machine_role}-${index} --zone=${zone}
EOF

    index=$(( $index + 1))
  done

}

## Launch permanent control plane
echo "$(date -u --rfc-3339=seconds) - Launching permanent control plane..."
create_cluster_machines "master" "${INFRA_ID}" "${CONTROL_SUBNET}" "${CLUSTER_IMAGE}" "${CONTROL_PLANE_NODE_TYPE}" "128" "${MASTER_SERVICE_ACCOUNT}" "${MASTER_IGNITION}" "${CONTROL_PLANE_DEPROVISION_SCRIPTS}" "${ZONE_0}" "${ZONE_1}" "${ZONE_2}"

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
echo "$(date -u --rfc-3339=seconds) - Adding control plane instances to load balancers..."
cmd="gcloud compute instance-groups unmanaged add-instances ${MASTER_IG_0} --zone=${ZONE_0} --instances=${INFRA_ID}-master-0"
run_command "${cmd}"
cmd="gcloud compute instance-groups unmanaged add-instances ${MASTER_IG_1} --zone=${ZONE_1} --instances=${INFRA_ID}-master-1"
run_command "${cmd}"
cmd="gcloud compute instance-groups unmanaged add-instances ${MASTER_IG_2} --zone=${ZONE_2} --instances=${INFRA_ID}-master-2"
run_command "${cmd}"
### Add control plan instances to internal load balancer backend-service
cmd="gcloud compute backend-services add-backend ${API_INTERNAL_BACKEND_SVC} --region=${REGION} --instance-group=${MASTER_IG_0} --instance-group-zone=${ZONE_0}"
run_command "${cmd}"
cmd="gcloud compute backend-services add-backend ${API_INTERNAL_BACKEND_SVC} --region=${REGION} --instance-group=${MASTER_IG_1} --instance-group-zone=${ZONE_1}"
run_command "${cmd}"
cmd="gcloud compute backend-services add-backend ${API_INTERNAL_BACKEND_SVC} --region=${REGION} --instance-group=${MASTER_IG_2} --instance-group-zone=${ZONE_2}"
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

## Launch additional compute nodes
echo "$(date -u --rfc-3339=seconds) - Launching additional compute nodes..."
## Available zones and instance zones might be different in region for arm64 machines
mapfile -t WORKER_INSTANCE_ZONES < <(gcloud compute machine-types list --filter="zone:(${REGION}) AND name=(${COMPUTE_NODE_TYPE})" --format=json | jq -r '.[].zone')
mapfile -t WORKER_ZONES < <(echo "${AVAILABILITY_ZONES[@]}" "${WORKER_INSTANCE_ZONES[@]}" | sed 's/ /\n/g' | sort -R | uniq -d)
create_cluster_machines "worker" "${INFRA_ID}" "${COMPUTE_SUBNET}" "${CLUSTER_IMAGE}" "${COMPUTE_NODE_TYPE}" "128" "${WORKER_SERVICE_ACCOUNT}" "${WORKER_IGNITION}" "${WORKER_DEPROVISION_SCRIPTS}" "${WORKER_ZONES[(( 0 % ${#WORKER_ZONES[@]} ))]}" "${WORKER_ZONES[(( 1 % ${#WORKER_ZONES[@]} ))]}"

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
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

gsutil rm "gs://${INFRA_ID}-bootstrap-ignition/bootstrap.ign"
gsutil rb "gs://${INFRA_ID}-bootstrap-ignition"
source "${SHARED_DIR}/04_bootstrap_deprovision.sh"

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
