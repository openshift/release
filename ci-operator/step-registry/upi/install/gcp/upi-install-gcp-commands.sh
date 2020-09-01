#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

mkdir -p "${ARTIFACT_DIR}/junit"
mkfifo /tmp/junit-pipe
python -c "
import time

start = time.time()
tests = []
test = {}
done = False
while not done:
    with open('/tmp/junit-pipe', 'r') as f:
        for line in f:
            print('read {!r}'.format(line))
            if line.strip() == 'done':
                done = True
                break
            verb_obj = line.strip().split(' ', 1)
            verb = verb_obj[0]
            if len(verb_obj) > 1:
                obj = verb_obj[1]
            if verb == 'start':
                test['start'] = time.time()
                test['name'] = obj
                continue
            test['duration'] = time.time() - test['start']
            if verb == 'fail':
                test['failure'] = obj
            tests.append(test)
            test = {}
if 'start' in test and 'duration' not in test:
    test['duration'] = time.time() - test['start']
    test'failure'] = 'unknown'
    tests.append(test)
end = time.time()

with open('${ARTIFACT_DIR}/junit/junit_install.xml', 'w') as f:
    f.write('<testsuite name=\"Cluster install\" tests=\"{}\" failures=\"{}\" skipped=\"0\" time=\"{}\">\n'.format(len(tests), len([t for t in tests if 'failure' in t]), int(end - start)))
    for t in tests:
        f.write('<testcase name=\"{name}\" time=\"{duration}\">\n'.format(**t))
        if 'failure' in t:
            f.write('<failure message="">{failure}</failure>\n'.format(**t))
    f.write('</testsuite>\n')
" &
WRITE_JUNIT_PID="$!"

function die() {
	echo fail "${@}" >/tmp/junit-pipe
	exit 1
}

trap 'echo done >/tmp/junit-pipe &; wait' EXIT
trap 'echo done >/tmp/junit-pipe &; sleep 1; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp

export SSH_PRIV_KEY_PATH="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}"

echo "$(date -u --rfc-3339=seconds) - Configuring gcloud..."
echo 'start configure-gcloud' >/tmp/junit-pipe
export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}" || die 'activate-service-account'
gcloud config set project "$(jq -r .gcp.projectID "${SHARED_DIR}/metadata.json")" || die 'set project'
echo pass >/tmp/junit-pipe

echo "$(date -u --rfc-3339=seconds) - Copying config from shared dir..."
echo 'start assemble configuration' >/tmp/junit-pipe
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

## Export variables to be used in examples below.
echo "$(date -u --rfc-3339=seconds) - Exporting variables..."
BASE_DOMAIN='origin-ci-int-gce.dev.openshift.com'
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
else
  # Set HOST_PROJECT to the cluster project so commands with `--project` work in both scenarios.
  HOST_PROJECT="${PROJECT_NAME}"
fi
echo pass >/tmp/junit-pipe

## Create the VPC
echo "$(date -u --rfc-3339=seconds) - Creating the VPC..."
echo 'start create VPC' >/tmp/junit-pipe
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Using pre-existing XPN VPC..."
  CLUSTER_NETWORK="${HOST_PROJECT_NETWORK}"
  COMPUTE_SUBNET="${HOST_PROJECT_COMPUTE_SUBNET}"
  CONTROL_SUBNET="${HOST_PROJECT_CONTROL_SUBNET}"
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

  gcloud deployment-manager deployments create "${INFRA_ID}-vpc" --config 01_vpc.yaml || die 'create deployment'

  ## Configure VPC variables
  CLUSTER_NETWORK="$(gcloud compute networks describe "${INFRA_ID}-network" --format json | jq -r .selfLink)"
  CONTROL_SUBNET="$(gcloud compute networks subnets describe "${INFRA_ID}-master-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
  COMPUTE_SUBNET="$(gcloud compute networks subnets describe "${INFRA_ID}-worker-subnet" "--region=${REGION}" --format json | jq -r .selfLink)"
fi
echo pass >/tmp/junit-pipe

## Create DNS entries and load balancers
echo "$(date -u --rfc-3339=seconds) - Creating load balancers and DNS zone..."
echo 'start create load balancers and DNS zone' >/tmp/junit-pipe
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
gcloud --project="${HOST_PROJECT}" dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
gcloud --project="${HOST_PROJECT}" dns record-sets transaction add "${CLUSTER_IP}" --name "api.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud --project="${HOST_PROJECT}" dns record-sets transaction add "${CLUSTER_IP}" --name "api-int.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud --project="${HOST_PROJECT}" dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"

### Add external DNS entries (optional)
echo "$(date -u --rfc-3339=seconds) - Adding external DNS entries..."
if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud dns record-sets transaction start --zone "${BASE_DOMAIN_ZONE_NAME}"
gcloud dns record-sets transaction add "${CLUSTER_PUBLIC_IP}" --name "api.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${BASE_DOMAIN_ZONE_NAME}"
gcloud dns record-sets transaction execute --zone "${BASE_DOMAIN_ZONE_NAME}"

echo pass >/tmp/junit-pipe

## Create firewall rules and IAM roles
echo "$(date -u --rfc-3339=seconds) - Creating service accounts and firewall rules..."
echo 'start service accounts and firewall rules' >/tmp/junit-pipe
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
echo pass >/tmp/junit-pipe

## Create the cluster image.
echo "$(date -u --rfc-3339=seconds) - Creating the cluster image..."
echo 'start create cluster image' >/tmp/junit-pipe
IMAGE_SOURCE="$(jq -r .gcp.url /var/lib/openshift-install/rhcos.json)"
gcloud compute images create "${INFRA_ID}-rhcos-image" --source-uri="${IMAGE_SOURCE}"
CLUSTER_IMAGE="$(gcloud compute images describe "${INFRA_ID}-rhcos-image" --format json | jq -r .selfLink)"
echo pass >/tmp/junit-pipe

## Upload the bootstrap.ign to a new bucket
echo "$(date -u --rfc-3339=seconds) - Uploading the bootstrap.ign to a new bucket..."
echo 'start upload bootstrap Ignition config' >/tmp/junit-pipe
gsutil mb "gs://${INFRA_ID}-bootstrap-ignition"
gsutil cp bootstrap.ign "gs://${INFRA_ID}-bootstrap-ignition/"

BOOTSTRAP_IGN="$(gsutil signurl -d 1h service-account-key.json "gs://${INFRA_ID}-bootstrap-ignition/bootstrap.ign" | grep "^gs:" | awk '{print $5}')"
echo pass >/tmp/junit-pipe

## Launch temporary bootstrap resources
echo "$(date -u --rfc-3339=seconds) - Launching temporary bootstrap resources..."
echo 'start launch bootstrap resources' >/tmp/junit-pipe
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

## Add the bootstrap instance to the load balancers
echo "$(date -u --rfc-3339=seconds) - Adding the bootstrap instance to the load balancers..."
if [ -f 02_lb_int.py ]; then # for workflow using internal load balancers
  # https://github.com/openshift/installer/pull/3270
  # https://github.com/openshift/installer/pull/3309
  gcloud compute instance-groups unmanaged add-instances "${INFRA_ID}-bootstrap-instance-group" "--zone=${ZONE_0}" "--instances=${INFRA_ID}-bootstrap"
  gcloud compute backend-services add-backend "${INFRA_ID}-api-internal-backend-service" "--region=${REGION}" "--instance-group=${INFRA_ID}-bootstrap-instance-group" "--instance-group-zone=${ZONE_0}"
else # for workflow before internal load balancers
  gcloud compute target-pools add-instances "${INFRA_ID}-ign-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-bootstrap"
  gcloud compute target-pools add-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-bootstrap"
fi

BOOTSTRAP_IP="$(gcloud compute addresses describe --region "${REGION}" "${INFRA_ID}-bootstrap-public-ip" --format json | jq -r .address)"
GATHER_BOOTSTRAP_ARGS=('--bootstrap' "${BOOTSTRAP_IP}")
echo pass >/tmp/junit-pipe

## Launch permanent control plane
echo "$(date -u --rfc-3339=seconds) - Launching permanent control plane..."
echo 'start launch permanent control plane' >/tmp/junit-pipe
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
gcloud "--project=${HOST_PROJECT}" dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
gcloud "--project=${HOST_PROJECT}" dns record-sets transaction add "${MASTER0_IP}" --name "etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud "--project=${HOST_PROJECT}" dns record-sets transaction add "${MASTER1_IP}" --name "etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud "--project=${HOST_PROJECT}" dns record-sets transaction add "${MASTER2_IP}" --name "etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type A --zone "${PRIVATE_ZONE_NAME}"
gcloud "--project=${HOST_PROJECT}" dns record-sets transaction add \
  "0 10 2380 etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  "0 10 2380 etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  "0 10 2380 etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}." \
  --name "_etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type SRV --zone "${PRIVATE_ZONE_NAME}"
gcloud "--project=${HOST_PROJECT}" dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"

## Add control plane instances to load balancers
echo "$(date -u --rfc-3339=seconds) - Adding control plane instances to load balancers..."
if [ -f 02_lb_int.py ]; then # for workflow using internal load balancers
  # https://github.com/openshift/installer/pull/3270
  gcloud compute instance-groups unmanaged add-instances "${INFRA_ID}-master-${ZONE_0}-instance-group" "--zone=${ZONE_0}" "--instances=${INFRA_ID}-${MASTER}-0"
  gcloud compute instance-groups unmanaged add-instances "${INFRA_ID}-master-${ZONE_1}-instance-group" "--zone=${ZONE_1}" "--instances=${INFRA_ID}-${MASTER}-1"
  gcloud compute instance-groups unmanaged add-instances "${INFRA_ID}-master-${ZONE_2}-instance-group" "--zone=${ZONE_2}" "--instances=${INFRA_ID}-${MASTER}-2"
else # for workflow before internal load balancers
  gcloud compute target-pools add-instances "${INFRA_ID}-ign-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-${MASTER}-0"
  gcloud compute target-pools add-instances "${INFRA_ID}-ign-target-pool" "--instances-zone=${ZONE_1}" "--instances=${INFRA_ID}-${MASTER}-1"
  gcloud compute target-pools add-instances "${INFRA_ID}-ign-target-pool" "--instances-zone=${ZONE_2}" "--instances=${INFRA_ID}-${MASTER}-2"
fi

### Add control plane instances to external load balancer target pools (optional)
gcloud compute target-pools add-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-${MASTER}-0"
gcloud compute target-pools add-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_1}" "--instances=${INFRA_ID}-${MASTER}-1"
gcloud compute target-pools add-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_2}" "--instances=${INFRA_ID}-${MASTER}-2"
echo pass >/tmp/junit-pipe

## Launch additional compute nodes
echo "$(date -u --rfc-3339=seconds) - Launching additional compute nodes..."
echo 'start launch compute nodes' >/tmp/junit-pipe
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
pass >/tmp/junit-pipe

## Monitor for `bootstrap-complete`
echo "$(date -u --rfc-3339=seconds) - Monitoring for bootstrap to complete"
echo 'start bootstrap complete'
openshift-install --dir="${dir}" wait-for bootstrap-complete &

set +e
wait "$!"
ret="$?"
set -e

if [ "$ret" -ne 0 ]; then
	echo 'fail bootstrap-complete' >/tmp/junit-pipe
  set +e
  # Attempt to gather bootstrap logs.
  echo "$(date -u --rfc-3339=seconds) - Bootstrap failed, attempting to gather bootstrap logs..."
  openshift-install "--dir=${dir}" gather bootstrap --key "${SSH_PRIV_KEY_PATH}" "${GATHER_BOOTSTRAP_ARGS[@]}"
  sed 's/password: .*/password: REDACTED/' "${dir}/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"
  cp log-bundle-*.tar.gz "${ARTIFACT_DIR}"
  set -e
  exit "$ret"
fi
echo pass >/tmp/junit-pipe

## Destroy bootstrap resources
echo "$(date -u --rfc-3339=seconds) - Bootstrap complete, destroying bootstrap resources"
echo 'start destroy bootstrap resources' >/tmp/junit-pipe
if [ -f 02_lb_int.py ]; then # for workflow using internal load balancers
  # https://github.com/openshift/installer/pull/3270
  # https://github.com/openshift/installer/pull/3309
  gcloud compute backend-services remove-backend "${INFRA_ID}-api-internal-backend-service" "--region=${REGION}" "--instance-group=${INFRA_ID}-bootstrap-instance-group" "--instance-group-zone=${ZONE_0}"
else # for workflow before internal load balancers
  gcloud compute target-pools remove-instances "${INFRA_ID}-ign-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-bootstrap"
  gcloud compute target-pools remove-instances "${INFRA_ID}-api-target-pool" "--instances-zone=${ZONE_0}" "--instances=${INFRA_ID}-bootstrap"
fi
gsutil rm "gs://${INFRA_ID}-bootstrap-ignition/bootstrap.ign"
gsutil rb "gs://${INFRA_ID}-bootstrap-ignition"
gcloud deployment-manager deployments delete -q "${INFRA_ID}-bootstrap"
echo pass >/tmp/junit-pipe

## Approving the CSR requests for nodes
echo "$(date -u --rfc-3339=seconds) - Approving the CSR requests for nodes..."
function approve_csrs() {
  while true; do
    oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve
    sleep 15 &
    wait "$!"
    continue
  done
}
approve_csrs &

## Wait for the default-router to have an external ip...(and not <pending>)
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Waiting for the default-router to have an external ip..."
  echo 'start wait for default router' >/tmp/junit-pipe
  set +e
  ROUTER_IP="$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')"
  while [[ "$ROUTER_IP" == "" || "$ROUTER_IP" == "<pending>" ]]; do
    sleep 10;
    ROUTER_IP="$(oc -n openshift-ingress get service router-default --no-headers | awk '{print $4}')"
  done
  set -e
  echo pass >/tmp/junit-pipe
fi

## Create default router dns entries
if [[ -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Creating default router DNS entries..."
  echo 'start create default router DNS entries' >/tmp/junit-pipe
  if [ -f transaction.yaml ]; then rm transaction.yaml; fi
  gcloud "--project=${HOST_PROJECT}" dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
  gcloud "--project=${HOST_PROJECT}" dns record-sets transaction add "${ROUTER_IP}" --name "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 300 --type A --zone "${PRIVATE_ZONE_NAME}"
  gcloud "--project=${HOST_PROJECT}" dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"

  if [ -f transaction.yaml ]; then rm transaction.yaml; fi
  gcloud dns record-sets transaction start --zone "${BASE_DOMAIN_ZONE_NAME}"
  gcloud dns record-sets transaction add "${ROUTER_IP}" --name "*.apps.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 300 --type A --zone "${BASE_DOMAIN_ZONE_NAME}"
  gcloud dns record-sets transaction execute --zone "${BASE_DOMAIN_ZONE_NAME}"
  echo pass >/tmp/junit-pipe
fi

## Monitor for cluster completion
echo "$(date -u --rfc-3339=seconds) - Monitoring for cluster completion..."
echo 'start wait for install-complete' >/tmp/junit-pipe
openshift-install --dir="${dir}" wait-for install-complete 2>&1 | grep --line-buffered -v password &

set +e
wait "$!"
ret="$?"
set -e

sed 's/password: .*/password: REDACTED/' "${dir}/.openshift_install.log" >>"${ARTIFACT_DIR}/.openshift_install.log"

if [ $ret -ne 0 ]; then
  echo 'fail install-complete' >/tmp/junit-pipe
  exit "$ret"
fi
echo pass >/tmp/junit-pipe

cp -t "${SHARED_DIR}" \
    "${dir}/auth/kubeconfig"

popd
