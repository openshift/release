#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

INSTALL_STAGE="initial"

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
#Save install status for must-gather to generate junit
trap 'echo "$? $INSTALL_STAGE" > "${SHARED_DIR}/install-status.txt"' EXIT TERM

export HOME=/tmp

export SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}"

echo "$(date -u --rfc-3339=seconds) - Configuring gcloud..."

if ! gcloud --version; then
  GCLOUD_TAR="google-cloud-sdk-256.0.0-linux-x86_64.tar.gz"
  GCLOUD_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$GCLOUD_TAR"
  echo "$(date -u --rfc-3339=seconds) - gcloud not installed: installing from $GCLOUD_URL"
  pushd ${HOME}
  curl -O "$GCLOUD_URL"
  tar -xzf "$GCLOUD_TAR"
  export PATH=${HOME}/google-cloud-sdk/bin:${PATH}
  popd
fi

export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "$(jq -r .gcp.projectID "${SHARED_DIR}/metadata.json")"
fi

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

KUBECONFIG="${dir}/auth/kubeconfig"
export KUBECONFIG
CLUSTER_NAME="$(jq -r .clusterName metadata.json)"
INFRA_ID="$(jq -r .infraID metadata.json)"
PROJECT_NAME="$(jq -r .gcp.projectID metadata.json)"
REGION="$(jq -r .gcp.region metadata.json)"
ZONE_0="$(gcloud compute regions describe "${REGION}" --format=json | jq -r .zones[0] | cut -d "/" -f9)"
ZONE_1="$(gcloud compute regions describe "${REGION}" --format=json | jq -r .zones[1] | cut -d "/" -f9)"
ZONE_2="$(gcloud compute regions describe "${REGION}" --format=json | jq -r .zones[2] | cut -d "/" -f9)"

MASTER_IGNITION="$(cat master.ign)"
WORKER_IGNITION="$(cat worker.ign)"

echo "Using infra_id: ${INFRA_ID}"

### Read XPN config, if exists
if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  echo "Reading variables from ${SHARED_DIR}/xpn.json..."
  IS_XPN=1
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_NETWORK="$(jq -r '.clusterNetwork' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_COMPUTE_SUBNET="$(jq -r '.computeSubnet' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_CONTROL_SUBNET="$(jq -r '.controlSubnet' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_COMPUTE_SERVICE_ACCOUNT="$(jq -r '.computeServiceAccount' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_CONTROL_SERVICE_ACCOUNT="$(jq -r '.controlServiceAccount' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_PRIVATE_ZONE_NAME="$(jq -r '.privateZoneName' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_PRIVATE_ZONE_DNS_NAME="$(gcloud --project="${HOST_PROJECT}" dns managed-zones list --filter="name~${HOST_PROJECT_PRIVATE_ZONE_NAME}" --format json | jq -r '.[].dnsName' | sed 's/.$//')"
  echo ">>HOST_PROJECT_PRIVATE_ZONE_DNS_NAME: '${HOST_PROJECT_PRIVATE_ZONE_DNS_NAME}'"
  gcloud --project="${HOST_PROJECT}" dns managed-zones list

  #project_option="--project=${HOST_PROJECT} --account=${HOST_PROJECT_ACCOUNT}"
  project_option="--project=${HOST_PROJECT}"
else
  # Set HOST_PROJECT to the cluster project so commands with `--project` work in both scenarios.
  HOST_PROJECT="${PROJECT_NAME}"
  project_option=""
fi

## Configure VPC variables
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN VPC..."
  CLUSTER_NETWORK="${HOST_PROJECT_NETWORK}"
  COMPUTE_SUBNET="${HOST_PROJECT_COMPUTE_SUBNET}"
  CONTROL_SUBNET="${HOST_PROJECT_CONTROL_SUBNET}"
  REGION=$(echo ${CONTROL_SUBNET} | cut -d "/" -f9)
  ZONE_0="$(gcloud compute regions describe "${REGION}" --format=json | jq -r .zones[0] | cut -d "/" -f9)"
  ZONE_1="$(gcloud compute regions describe "${REGION}" --format=json | jq -r .zones[1] | cut -d "/" -f9)"
  ZONE_2="$(gcloud compute regions describe "${REGION}" --format=json | jq -r .zones[2] | cut -d "/" -f9)"
else
  CLUSTER_NETWORK="$(gcloud compute networks describe "${CLUSTER_NAME}-network" --format json | jq -r .selfLink)"
  CONTROL_SUBNET="$(gcloud compute networks subnets describe "${CLUSTER_NAME}-master-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
  COMPUTE_SUBNET="$(gcloud compute networks subnets describe "${CLUSTER_NAME}-worker-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
fi

## Create DNS entries and load balancers
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN private zone..."
  PRIVATE_ZONE_NAME="${HOST_PROJECT_PRIVATE_ZONE_NAME}"
  BASE_DOMAIN="${HOST_PROJECT_PRIVATE_ZONE_DNS_NAME}"
else
  echo "$(date -u --rfc-3339=seconds) - Creating DNS zone..."
  PRIVATE_ZONE_NAME="${INFRA_ID}-private-zone"
  cat <<EOF > 02_dns.yaml
imports:
- path: 02_dns.py
resources:
- name: cluster-dns
  type: 02_dns.py
  properties:
    infra_id: '${INFRA_ID}'
    cluster_domain: '${CLUSTER_NAME}.${BASE_DOMAIN}'
    cluster_network: '${CLUSTER_NETWORK}'
EOF
  gcloud deployment-manager deployments create "${INFRA_ID}-dns" --config 02_dns.yaml
fi
echo ">>----------------------"
gcloud ${project_option} dns managed-zones list --filter="name~${PRIVATE_ZONE_NAME}"
echo ">>----------------------"

if [ X"${PUBLISH_STRATEGY}" == X"Internal" ]; then
  cat <<EOF > 02_infra.yaml
imports:
- path: 02_lb_int.py
resources:
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
else
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
fi
gcloud deployment-manager deployments create "${INFRA_ID}-infra" --config 02_infra.yaml

## Configure infra variables
CLUSTER_IP="$(gcloud compute addresses describe "${INFRA_ID}-cluster-ip" "--region=${REGION}" --format json | jq -r .address)"

### Add internal DNS entries
echo "$(date -u --rfc-3339=seconds) - Adding internal DNS entries..."
if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud ${project_option} dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
gcloud ${project_option} dns record-sets transaction add "${CLUSTER_IP}" --name "api.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${project_option} dns record-sets transaction add "${CLUSTER_IP}" --name "api-int.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${project_option} dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"

### Add external DNS entries (optional)
if [ X"${PUBLISH_STRATEGY}" != X"Internal" ]; then

  CLUSTER_PUBLIC_IP="$(gcloud compute addresses describe "${INFRA_ID}-cluster-public-ip" "--region=${REGION}" --format json | jq -r .address)"

  ret=$(gcloud ${project_option} dns managed-zones list --filter "name=${BASE_DOMAIN_ZONE_NAME}" 2> /dev/null)
  if [[ -z $ret ]]; then
    echo ">>The base domain ${BASE_DOMAIN_ZONE_NAME} doesn't exist in project ${HOST_PROJECT}."
  else
    echo "$(date -u --rfc-3339=seconds) - Adding external DNS entries..."
    if [ -f transaction.yaml ]; then rm transaction.yaml; fi
    gcloud ${project_option} dns record-sets transaction start --zone "${BASE_DOMAIN_ZONE_NAME}"
    gcloud ${project_option} dns record-sets transaction add "${CLUSTER_PUBLIC_IP}" --name "api.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${BASE_DOMAIN_ZONE_NAME}"
    gcloud ${project_option} dns record-sets transaction execute --zone "${BASE_DOMAIN_ZONE_NAME}"
  fi
fi

## Create firewall rules
echo "$(date -u --rfc-3339=seconds) - Creating firewall rules..."
allowed_external_cidr=""
if [ X"${PUBLISH_STRATEGY}" == X"Internal" ]; then
	allowed_external_cidr="${NETWORK_CIDR}"
else
	allowed_external_cidr="0.0.0.0/0"
fi
cat <<EOF > 03_firewall.yaml
imports:
- path: 03_firewall.py
resources:
- name: cluster-firewall
  type: 03_firewall.py
  properties:
    allowed_external_cidr: '${allowed_external_cidr}'
    infra_id: '${INFRA_ID}'
    cluster_network: '${CLUSTER_NETWORK}'
    network_cidr: '${NETWORK_CIDR}'
EOF
gcloud ${project_option} deployment-manager deployments create "${INFRA_ID}-firewall" --config 03_firewall.yaml

## Create IAM roles
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing IAM service-accounts..."
  MASTER_SERVICE_ACCOUNT=${HOST_PROJECT_CONTROL_SERVICE_ACCOUNT}
  WORKER_SERVICE_ACCOUNT=${HOST_PROJECT_COMPUTE_SERVICE_ACCOUNT}
else
  echo "$(date -u --rfc-3339=seconds) - Creating IAM service-accounts and granting roles..."
  cat <<EOF > 03_iam.yaml
imports:
- path: 03_iam.py
resources:
- name: cluster-iam
  type: 03_iam.py
  properties:
    infra_id: '${INFRA_ID}'
EOF
  gcloud deployment-manager deployments create "${INFRA_ID}-iam" --config 03_iam.yaml

  ## Configure security variables
  tries=0
  while [[ -z ${MASTER_SERVICE_ACCOUNT+x} || -z ${WORKER_SERVICE_ACCOUNT+x} ]]; do
    MASTER_SERVICE_ACCOUNT="$(gcloud iam service-accounts list --filter "email~^${INFRA_ID}-m@${PROJECT_NAME}." --format json | jq -r '.[0].email')"
    WORKER_SERVICE_ACCOUNT="$(gcloud iam service-accounts list --filter "email~^${INFRA_ID}-w@${PROJECT_NAME}." --format json | jq -r '.[0].email')"
    sleep 1s && tries=$(($tries + 1))
    if [ $tries -gt 5 ]; then break; fi
  done
  echo ">>MASTER_SERVICE_ACCOUNT: ${MASTER_SERVICE_ACCOUNT}"
  echo ">>WORKER_SERVICE_ACCOUNT: ${WORKER_SERVICE_ACCOUNT}"

  ## Add required roles to IAM service accounts
  echo "$(date -u --rfc-3339=seconds) - Granting required roles to IAM service accounts..."
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

## Create the cluster image.
echo "$(date -u --rfc-3339=seconds) - Creating the cluster image..."
imagename="${INFRA_ID}-rhcos-image"
# https://github.com/openshift/installer/blob/master/docs/user/overview.md#coreos-bootimages
# This code needs to handle pre-4.8 installers though too.
if openshift-install coreos print-stream-json 2>/tmp/err.txt >coreos.json; then
  jq '.architectures.'"$(uname -m)"'.images.gcp' < coreos.json > gcp.json
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
    machine_type: 'n1-standard-4'
    root_volume_size: '128'
    bootstrap_ign: '${BOOTSTRAP_IGN}'
EOF
gcloud deployment-manager deployments create "${INFRA_ID}-bootstrap" --config 04_bootstrap.yaml
BOOTSTRAP_INSTANCE_GROUP=$(gcloud compute instance-groups list --filter "network:${CLUSTER_NETWORK} AND name~^${INFRA_ID}-bootstrap-" --format "value(name)")

## Add the bootstrap instance to the load balancers
echo "$(date -u --rfc-3339=seconds) - Adding the bootstrap instance to the load balancers..."
gcloud compute instance-groups unmanaged add-instances "${BOOTSTRAP_INSTANCE_GROUP}" "--zone=${ZONE_0}" "--instances=${INFRA_ID}-bootstrap"
gcloud compute backend-services add-backend "${INFRA_ID}-api-internal-backend-service" "--region=${REGION}" "--instance-group=${BOOTSTRAP_INSTANCE_GROUP}" "--instance-group-zone=${ZONE_0}"

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
    machine_type: 'n1-standard-4'
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
gcloud ${project_option} dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
gcloud ${project_option} dns record-sets transaction add "${MASTER0_IP}" --name "etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${project_option} dns record-sets transaction add "${MASTER1_IP}" --name "etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${project_option} dns record-sets transaction add "${MASTER2_IP}" --name "etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud ${project_option} dns record-sets transaction add \
  "0 10 2380 etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  "0 10 2380 etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  "0 10 2380 etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  --name "_etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type SRV --zone "${PRIVATE_ZONE_NAME}"
gcloud ${project_option} dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"

MASTER_IG_0="$(gcloud compute instance-groups list --filter "network:${CLUSTER_NETWORK} AND name~^${INFRA_ID}-master-${ZONE_0}-" --format "value(name)")"
MASTER_IG_1="$(gcloud compute instance-groups list --filter "network:${CLUSTER_NETWORK} AND name~^${INFRA_ID}-master-${ZONE_1}-" --format "value(name)")"
MASTER_IG_2="$(gcloud compute instance-groups list --filter "network:${CLUSTER_NETWORK} AND name~^${INFRA_ID}-master-${ZONE_2}-" --format "value(name)")"
## Add control plane instances to load balancers
echo "$(date -u --rfc-3339=seconds) - Adding control plane instances to load balancers..."
gcloud compute instance-groups unmanaged add-instances "${MASTER_IG_0}" "--zone=${ZONE_0}" "--instances=${INFRA_ID}-${MASTER}-0"
gcloud compute instance-groups unmanaged add-instances "${MASTER_IG_1}" "--zone=${ZONE_1}" "--instances=${INFRA_ID}-${MASTER}-1"
gcloud compute instance-groups unmanaged add-instances "${MASTER_IG_2}" "--zone=${ZONE_2}" "--instances=${INFRA_ID}-${MASTER}-2"

### Add control plane instances to external load balancer target pools (optional)
if [ X"${PUBLISH_STRATEGY}" != X"Internal" ]; then
  gcloud compute target-pools add-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-${MASTER}-0"
  gcloud compute target-pools add-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_1}" "--instances=${INFRA_ID}-${MASTER}-1"
  gcloud compute target-pools add-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_2}" "--instances=${INFRA_ID}-${MASTER}-2"
fi

## Launch additional compute nodes
echo "$(date -u --rfc-3339=seconds) - Launching additional compute nodes..."
mapfile -t ZONES < <(gcloud compute regions describe "${REGION}" --format=json | jq -r .zones[] | cut -d '/' -f9)
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
    zone: '${ZONES[(( $compute % ${#ZONES[@]} ))]}'
    compute_subnet: '${COMPUTE_SUBNET}'
    image: '${CLUSTER_IMAGE}'
    machine_type: 'n1-standard-4'
    root_volume_size: '128'
    service_account_email: '${WORKER_SERVICE_ACCOUNT}'
    ignition: '${WORKER_IGNITION}'
EOF
done;
gcloud deployment-manager deployments create "${INFRA_ID}-worker" --config 06_worker.yaml

# enable client http proxy
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Enable HTTP proxy, as it'll be a private cluster..."
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

INSTALL_STAGE="bootstrap_successful"

## Destroy bootstrap resources
echo "$(date -u --rfc-3339=seconds) - Bootstrap complete, destroying bootstrap resources"
gcloud compute backend-services remove-backend "${INFRA_ID}-api-internal-backend-service" "--region=${REGION}" "--instance-group=${BOOTSTRAP_INSTANCE_GROUP}" "--instance-group-zone=${ZONE_0}"
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

## Create default router dns entries (XPN means 'add_ingress_records_manually'? <jiwei>)
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Creating default router DNS entries..."
  if [ -f transaction.yaml ]; then rm transaction.yaml; fi
  gcloud ${project_option} dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
  gcloud ${project_option} dns record-sets transaction add "${ROUTER_IP}" --name "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 300 --type A --zone "${PRIVATE_ZONE_NAME}"
  gcloud ${project_option} dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"

  if [ X"${PUBLISH_STRATEGY}" != X"Internal" ]; then
    ret=$(gcloud --project="${HOST_PROJECT}" dns managed-zones list --filter "name=${BASE_DOMAIN_ZONE_NAME}" 2> /dev/null)
    if [[ -z $ret ]]; then
      echo ">>The base domain ${BASE_DOMAIN_ZONE_NAME} doesn't exist in project ${HOST_PROJECT}."
    else
      if [ -f transaction.yaml ]; then rm transaction.yaml; fi
      gcloud ${project_option} dns record-sets transaction start --zone "${BASE_DOMAIN_ZONE_NAME}"
      gcloud ${project_option} dns record-sets transaction add "${ROUTER_IP}" --name "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 300 --type A --zone "${BASE_DOMAIN_ZONE_NAME}"
      gcloud ${project_option} dns record-sets transaction execute --zone "${BASE_DOMAIN_ZONE_NAME}"
    fi
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

INSTALL_STAGE="cluster_creation_successful"

cp -t "${SHARED_DIR}" \
    "${dir}/auth/kubeconfig"

popd
touch /tmp/install-complete
