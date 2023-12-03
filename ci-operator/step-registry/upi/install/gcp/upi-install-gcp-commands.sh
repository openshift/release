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

  dir=$(mktemp -d)
  pushd "${dir}"

  cp ${CLUSTER_PROFILE_DIR}/pull-secret pull-secret
  KUBECONFIG="" oc registry login --to pull-secret
  ocp_version=$(oc adm release info --registry-config pull-secret ${TESTING_RELEASE_IMAGE} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)

  if [[ "${ocp_version}" == "${minimum_version}" ]] || [[ "${ocp_version}" > "${minimum_version}" ]]; then
    ret=0
  else
    ret=1
  fi

  rm pull-secret
  popd
  return ${ret}
}

echo "$(date -u --rfc-3339=seconds) - Configuring gcloud..."
if version_check "4.12"; then
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
        "$@" && failed=0 || failed=1
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
  cat <<EOF > 01_vpc.yaml
imports:
- path: 01_vpc.py
resources:
- name: cluster-vpc
  type: 01_vpc.py
  properties:
    infra_id: '${INFRA_ID}'
    region: '${REGION}'
    master_subnet_cidr: '${MASTER_SUBNET_CIDR}'
    worker_subnet_cidr: '${WORKER_SUBNET_CIDR}'
EOF
  gcloud deployment-manager deployments create "${INFRA_ID}-vpc" --config 01_vpc.yaml

  ## Configure VPC variables
  CLUSTER_NETWORK="$(gcloud compute networks describe "${INFRA_ID}-network" --format json | jq -r .selfLink)"
  CONTROL_SUBNET="$(gcloud compute networks subnets describe "${INFRA_ID}-master-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
  COMPUTE_SUBNET="$(gcloud compute networks subnets describe "${INFRA_ID}-worker-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
fi

## Create DNS entries and load balancers
echo "$(date -u --rfc-3339=seconds) - Creating load balancers and DNS zone..."
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN private zone..."
  PRIVATE_ZONE_NAME="${HOST_PROJECT_PRIVATE_ZONE_NAME}"
  cat <<EOF > 02_infra.yaml
imports:
- path: 02_lb_ext.py
- path: 02_lb_int.py
resources:
- name: cluster-lb-ext
  type: 02_lb_ext.py
  properties:
    infra_id: '${INFRA_ID}'
    region: '${REGION}'
- name: cluster-lb-int
  type: 02_lb_int.py
  properties:
    cluster_network: '${CLUSTER_NETWORK}'
    control_subnet: '${CONTROL_SUBNET}'
    infra_id: '${INFRA_ID}'
    region: '${REGION}'
    zones:
    - '${ZONE_0}'
    - '${ZONE_1}'
    - '${ZONE_2}'
EOF
elif [ -f 02_lb_int.py ]; then # for workflow using internal load balancers
  # https://github.com/openshift/installer/pull/3270
  # https://github.com/openshift/installer/pull/2574
  PRIVATE_ZONE_NAME="${INFRA_ID}-private-zone"
  cat <<EOF > 02_infra.yaml
imports:
- path: 02_dns.py
- path: 02_lb_ext.py
- path: 02_lb_int.py
resources:
- name: cluster-dns
  type: 02_dns.py
  properties:
    infra_id: '${INFRA_ID}'
    cluster_domain: '${CLUSTER_NAME}.${BASE_DOMAIN}'
    cluster_network: '${CLUSTER_NETWORK}'
- name: cluster-lb-ext
  type: 02_lb_ext.py
  properties:
    infra_id: '${INFRA_ID}'
    region: '${REGION}'
- name: cluster-lb-int
  type: 02_lb_int.py
  properties:
    cluster_network: '${CLUSTER_NETWORK}'
    control_subnet: '${CONTROL_SUBNET}'
    infra_id: '${INFRA_ID}'
    region: '${REGION}'
    zones:
    - '${ZONE_0}'
    - '${ZONE_1}'
    - '${ZONE_2}'
EOF
else # for workflow before splitting up 02_infra.py
  PRIVATE_ZONE_NAME="${INFRA_ID}-private-zone"
  cat <<EOF > 02_infra.yaml
imports:
- path: 02_infra.py
resources:
- name: cluster-infra
  type: 02_infra.py
  properties:
    infra_id: '${INFRA_ID}'
    region: '${REGION}'
    cluster_domain: '${CLUSTER_NAME}.${BASE_DOMAIN}'
    cluster_network: '${CLUSTER_NETWORK}'
EOF
fi

gcloud deployment-manager deployments create "${INFRA_ID}-infra" --config 02_infra.yaml

## Configure infra variables
if [ -f 02_lb_int.py ]; then # workflow using internal load balancers
  # https://github.com/openshift/installer/pull/3270
  CLUSTER_IP="$(gcloud compute addresses describe "${INFRA_ID}-cluster-ip" "--region=${REGION}" --format json | jq -r .address)"
else # for workflow before internal load balancers
  CLUSTER_IP="$(gcloud compute addresses describe "${INFRA_ID}-cluster-public-ip" "--region=${REGION}" --format json | jq -r .address)"
fi
CLUSTER_PUBLIC_IP="$(gcloud compute addresses describe "${INFRA_ID}-cluster-public-ip" "--region=${REGION}" --format json | jq -r .address)"

### Add internal DNS entries
echo "$(date -u --rfc-3339=seconds) - Adding internal DNS entries..."
if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud ${PROJECT_OPTION} dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
gcloud ${PROJECT_OPTION} dns record-sets transaction add "${CLUSTER_IP}" --name "api.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${PROJECT_OPTION} dns record-sets transaction add "${CLUSTER_IP}" --name "api-int.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${PROJECT_OPTION} dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"

### Add external DNS entries (optional)
echo "$(date -u --rfc-3339=seconds) - Adding external DNS entries..."
if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud dns record-sets transaction start --zone "${BASE_DOMAIN_ZONE_NAME}"
gcloud dns record-sets transaction add "${CLUSTER_PUBLIC_IP}" --name "api.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${BASE_DOMAIN_ZONE_NAME}"
gcloud dns record-sets transaction execute --zone "${BASE_DOMAIN_ZONE_NAME}"

## Create firewall rules and IAM roles
echo "$(date -u --rfc-3339=seconds) - Creating service accounts and firewall rules..."
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN firewall rules..."
  echo "$(date -u --rfc-3339=seconds) - using pre-existing XPN service accounts..."
  MASTER_SERVICE_ACCOUNT="${HOST_PROJECT_CONTROL_SERVICE_ACCOUNT}"
  WORKER_SERVICE_ACCOUNT="${HOST_PROJECT_COMPUTE_SERVICE_ACCOUNT}"
elif [ -f 03_firewall.py ]; then # for workflow using 03_iam.py and 03_firewall.py
  # https://github.com/openshift/installer/pull/2574
  cat <<EOF > 03_security.yaml
imports:
- path: 03_firewall.py
- path: 03_iam.py
resources:
- name: cluster-firewall
  type: 03_firewall.py
  properties:
    allowed_external_cidr: '0.0.0.0/0'
    infra_id: '${INFRA_ID}'
    cluster_network: '${CLUSTER_NETWORK}'
    network_cidr: '${NETWORK_CIDR}'
- name: cluster-iam
  type: 03_iam.py
  properties:
    infra_id: '${INFRA_ID}'
EOF
else # for  workflow before splitting out 03_firewall.py
  MASTER_NAT_IP="$(gcloud compute addresses describe "${INFRA_ID}-master-nat-ip" --region "${REGION}" --format json | jq -r .address)"
  WORKER_NAT_IP="$(gcloud compute addresses describe "${INFRA_ID}-worker-nat-ip" --region "${REGION}" --format json | jq -r .address)"
  cat <<EOF > 03_security.yaml
imports:
- path: 03_security.py
resources:
- name: cluster-security
  type: 03_security.py
  properties:
    infra_id: '${INFRA_ID}'
    cluster_network: '${CLUSTER_NETWORK}'
    network_cidr: '${NETWORK_CIDR}'
    master_nat_ip: '${MASTER_NAT_IP}'
    worker_nat_ip: '${WORKER_NAT_IP}'
EOF
fi

if [[ -f  03_security.yaml ]]; then
  gcloud deployment-manager deployments create "${INFRA_ID}-security" --config 03_security.yaml

  ## Configure security variables
  MASTER_SERVICE_ACCOUNT="$(gcloud iam service-accounts list --filter "email~^${INFRA_ID}-m@${PROJECT_NAME}." --format json | jq -r '.[0].email')"
  WORKER_SERVICE_ACCOUNT="$(gcloud iam service-accounts list --filter "email~^${INFRA_ID}-w@${PROJECT_NAME}." --format json | jq -r '.[0].email')"

  ## Add required roles to IAM service accounts
  echo "$(date -u --rfc-3339=seconds) - Adding required roles to IAM service accounts..."
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${MASTER_SERVICE_ACCOUNT}" --role "roles/compute.instanceAdmin"
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${MASTER_SERVICE_ACCOUNT}" --role "roles/compute.networkAdmin"
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${MASTER_SERVICE_ACCOUNT}" --role "roles/compute.securityAdmin"
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${MASTER_SERVICE_ACCOUNT}" --role "roles/iam.serviceAccountUser"
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${MASTER_SERVICE_ACCOUNT}" --role "roles/storage.admin"

  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${WORKER_SERVICE_ACCOUNT}" --role "roles/compute.viewer"
  backoff gcloud projects add-iam-policy-binding "${PROJECT_NAME}" --member "serviceAccount:${WORKER_SERVICE_ACCOUNT}" --role "roles/storage.admin"
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

## Launch temporary bootstrap resources
echo "$(date -u --rfc-3339=seconds) - Launching temporary bootstrap resources..."
cat <<EOF > 04_bootstrap.yaml
imports:
- path: 04_bootstrap.py
resources:
- name: cluster-bootstrap
  type: 04_bootstrap.py
  properties:
    infra_id: '${INFRA_ID}'
    region: '${REGION}'
    zone: '${ZONE_0}'
    cluster_network: '${CLUSTER_NETWORK}'
    control_subnet: '${CONTROL_SUBNET}'
    image: '${CLUSTER_IMAGE}'
    machine_type: '${BOOTSTRAP_NODE_TYPE}'
    root_volume_size: '128'
    bootstrap_ign: '${BOOTSTRAP_IGN}'
EOF

gcloud deployment-manager deployments create "${INFRA_ID}-bootstrap" --config 04_bootstrap.yaml
BOOTSTRAP_INSTANCE_GROUP=$(gcloud compute instance-groups list --filter "network:${CLUSTER_NETWORK} AND name~^${INFRA_ID}-bootstrap-" --format "value(name)")
## Add the bootstrap instance to the load balancers
echo "$(date -u --rfc-3339=seconds) - Adding the bootstrap instance to the load balancers..."
if [ -f 02_lb_int.py ]; then # for workflow using internal load balancers
  # https://github.com/openshift/installer/pull/3270
  # https://github.com/openshift/installer/pull/3309
  gcloud compute instance-groups unmanaged add-instances "${BOOTSTRAP_INSTANCE_GROUP}" "--zone=${ZONE_0}" "--instances=${INFRA_ID}-bootstrap"
  gcloud compute backend-services add-backend "${INFRA_ID}-api-internal-backend-service" "--region=${REGION}" "--instance-group=${BOOTSTRAP_INSTANCE_GROUP}" "--instance-group-zone=${ZONE_0}"
else # for workflow before internal load balancers
  gcloud compute target-pools add-instances "${INFRA_ID}-ign-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-bootstrap"
  gcloud compute target-pools add-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-bootstrap"
fi

BOOTSTRAP_IP="$(gcloud compute addresses describe --region "${REGION}" "${INFRA_ID}-bootstrap-public-ip" --format json | jq -r .address)"
GATHER_BOOTSTRAP_ARGS=('--bootstrap' "${BOOTSTRAP_IP}")

## Launch permanent control plane
echo "$(date -u --rfc-3339=seconds) - Launching permanent control plane..."
cat <<EOF > 05_control_plane.yaml
imports:
- path: 05_control_plane.py
resources:
- name: cluster-control-plane
  type: 05_control_plane.py
  properties:
    infra_id: '${INFRA_ID}'
    zones:
    - '${ZONE_0}'
    - '${ZONE_1}'
    - '${ZONE_2}'
    control_subnet: '${CONTROL_SUBNET}'
    image: '${CLUSTER_IMAGE}'
    machine_type: '${CONTROL_PLANE_NODE_TYPE}'
    root_volume_size: '128'
    service_account_email: '${MASTER_SERVICE_ACCOUNT}'
    ignition: '${MASTER_IGNITION}'
EOF

gcloud deployment-manager deployments create "${INFRA_ID}-control-plane" --config 05_control_plane.yaml

## Determine name of master nodes
# https://github.com/openshift/installer/pull/3713
set +e
grep -Fe '-master-0' 05_control_plane.py
ret="$?"
set -e
if [[ "$ret" == 0 ]]; then
  MASTER='master'
  WORKER='worker'
else
  MASTER='m'
  WORKER='w'
fi

## Configure control plane variables
MASTER0_IP="$(gcloud compute instances describe "${INFRA_ID}-${MASTER}-0" --zone "${ZONE_0}" --format json | jq -r .networkInterfaces[0].networkIP)"
MASTER1_IP="$(gcloud compute instances describe "${INFRA_ID}-${MASTER}-1" --zone "${ZONE_1}" --format json | jq -r .networkInterfaces[0].networkIP)"
MASTER2_IP="$(gcloud compute instances describe "${INFRA_ID}-${MASTER}-2" --zone "${ZONE_2}" --format json | jq -r .networkInterfaces[0].networkIP)"

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

MASTER_IG_0="$(gcloud compute instance-groups list --filter "network:${CLUSTER_NETWORK} AND name~^${INFRA_ID}-master-${ZONE_0}-" --format "value(name)")"
MASTER_IG_1="$(gcloud compute instance-groups list --filter "network:${CLUSTER_NETWORK} AND name~^${INFRA_ID}-master-${ZONE_1}-" --format "value(name)")"
MASTER_IG_2="$(gcloud compute instance-groups list --filter "network:${CLUSTER_NETWORK} AND name~^${INFRA_ID}-master-${ZONE_2}-" --format "value(name)")"
## Add control plane instances to load balancers
echo "$(date -u --rfc-3339=seconds) - Adding control plane instances to load balancers..."
if [ -f 02_lb_int.py ]; then # for workflow using internal load balancers
  # https://github.com/openshift/installer/pull/3270
  gcloud compute instance-groups unmanaged add-instances "${MASTER_IG_0}" "--zone=${ZONE_0}" "--instances=${INFRA_ID}-${MASTER}-0"
  gcloud compute instance-groups unmanaged add-instances "${MASTER_IG_1}" "--zone=${ZONE_1}" "--instances=${INFRA_ID}-${MASTER}-1"
  gcloud compute instance-groups unmanaged add-instances "${MASTER_IG_2}" "--zone=${ZONE_2}" "--instances=${INFRA_ID}-${MASTER}-2"
else # for workflow before internal load balancers
  gcloud compute target-pools add-instances "${INFRA_ID}-ign-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-${MASTER}-0"
  gcloud compute target-pools add-instances "${INFRA_ID}-ign-target-pool" "--instances-zone=${ZONE_1}" "--instances=${INFRA_ID}-${MASTER}-1"
  gcloud compute target-pools add-instances "${INFRA_ID}-ign-target-pool" "--instances-zone=${ZONE_2}" "--instances=${INFRA_ID}-${MASTER}-2"
fi

### Add control plane instances to external load balancer target pools (optional)
gcloud compute target-pools add-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-${MASTER}-0"
gcloud compute target-pools add-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_1}" "--instances=${INFRA_ID}-${MASTER}-1"
gcloud compute target-pools add-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_2}" "--instances=${INFRA_ID}-${MASTER}-2"

## Launch additional compute nodes
echo "$(date -u --rfc-3339=seconds) - Launching additional compute nodes..."
## Available zones and instance zones might be different in region for arm64 machines
mapfile -t WORKER_INSTANCE_ZONES < <(gcloud compute machine-types list --filter="zone:(${REGION}) AND name=(${COMPUTE_NODE_TYPE})" --format=json | jq -r '.[].zone')
mapfile -t WORKER_ZONES < <(echo "${AVAILABILITY_ZONES[@]}" "${WORKER_INSTANCE_ZONES[@]}" | sed 's/ /\n/g' | sort -R | uniq -d)
cat <<EOF > 06_worker.yaml
imports:
- path: 06_worker.py
resources:
EOF

for compute in {0..2}; do
  cat <<EOF >> 06_worker.yaml
- name: '${WORKER}-${compute}'
  type: 06_worker.py
  properties:
    infra_id: '${INFRA_ID}'
    zone: '${WORKER_ZONES[(( $compute % ${#WORKER_ZONES[@]} ))]}'
    compute_subnet: '${COMPUTE_SUBNET}'
    image: '${CLUSTER_IMAGE}'
    machine_type: '${COMPUTE_NODE_TYPE}'
    root_volume_size: '128'
    service_account_email: '${WORKER_SERVICE_ACCOUNT}'
    ignition: '${WORKER_IGNITION}'
EOF
done;

gcloud deployment-manager deployments create "${INFRA_ID}-worker" --config 06_worker.yaml

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
if [ -f 02_lb_int.py ]; then # for workflow using internal load balancers
  # https://github.com/openshift/installer/pull/3270
  # https://github.com/openshift/installer/pull/3309
  gcloud compute backend-services remove-backend "${INFRA_ID}-api-internal-backend-service" "--region=${REGION}" "--instance-group=${BOOTSTRAP_INSTANCE_GROUP}" "--instance-group-zone=${ZONE_0}"
else # for workflow before internal load balancers
  gcloud compute target-pools remove-instances "${INFRA_ID}-ign-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-bootstrap"
  gcloud compute target-pools remove-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-bootstrap"
fi
gsutil rm "gs://${INFRA_ID}-bootstrap-ignition/bootstrap.ign"
gsutil rb "gs://${INFRA_ID}-bootstrap-ignition"
gcloud deployment-manager deployments delete -q "${INFRA_ID}-bootstrap"

## Approving the CSR requests for nodes
echo "$(date -u --rfc-3339=seconds) - Approving the CSR requests for nodes..."
function approve_csrs() {
  while [[ ! -f /tmp/install-complete ]]; do
      # even if oc get csr fails continue
      oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      sleep 15 & wait
  done
}
approve_csrs &

## Wait for the default-router to have an external ip...(and not <pending>)
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Waiting for the default-router to have an external ip..."
  set +e
  ROUTER_IP="$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')"
  while [[ "$ROUTER_IP" == "" || "$ROUTER_IP" == "<pending>" ]]; do
    sleep 10;
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

  if [ -f transaction.yaml ]; then rm transaction.yaml; fi
  gcloud dns record-sets transaction start --zone "${BASE_DOMAIN_ZONE_NAME}"
  gcloud dns record-sets transaction add "${ROUTER_IP}" --name "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 300 --type A --zone "${BASE_DOMAIN_ZONE_NAME}"
  gcloud dns record-sets transaction execute --zone "${BASE_DOMAIN_ZONE_NAME}"
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
