#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"
if [ -f "${SHARED_DIR}/metadata.json" ]; then
  gcloud config set project "$(jq -r .gcp.projectID "${SHARED_DIR}/metadata.json")"
else
  #sa_email=$(jq -r .client_email ${GOOGLE_CLOUD_KEYFILE_JSON})
  #gcloud config set project "$(echo ${sa_email} | awk -F@ '{print $2}' | sed 's/\.iam\.gserviceaccount\.com//')"
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi

dir=/tmp/installer
mkdir -p "${dir}"
pushd "${dir}"

if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi
BASE_DOMAIN="$(cat ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
CLUSTER_NAME="$(jq -r .clusterName "${SHARED_DIR}/metadata.json")"
INFRA_ID="$(jq -r .infraID "${SHARED_DIR}/metadata.json")"

### Read XPN config, if exists
if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  echo "Reading variables from ${SHARED_DIR}/xpn.json..."
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_PRIVATE_ZONE_NAME="$(jq -r '.privateZoneName' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_PRIVATE_ZONE_DNS_NAME="$(gcloud --project="${HOST_PROJECT}" dns managed-zones list --filter="name~${HOST_PROJECT_PRIVATE_ZONE_NAME}" --format json | jq -r '.[].dnsName' | sed 's/.$//')"

  PRIVATE_ZONE_NAME="${HOST_PROJECT_PRIVATE_ZONE_NAME}"
  BASE_DOMAIN="${HOST_PROJECT_PRIVATE_ZONE_DNS_NAME}"

  #project_option="--project=${HOST_PROJECT} --account=${HOST_PROJECT_ACCOUNT}"
  project_option="--project=${HOST_PROJECT}"
else
  PRIVATE_ZONE_NAME="${INFRA_ID}-private-zone"
  project_option=""
fi
BASE_DOMAIN_ZONE_NAME="$(gcloud dns managed-zones list --filter "DNS_NAME=${BASE_DOMAIN}." --format json | jq -r .[0].name)"

# Delete the bootstrap deployment, if exists
echo "$(date -u --rfc-3339=seconds) - Deleting bootstrap deployment (errors when bootstrap-complete)..."
if gcloud deployment-manager deployments list --filter="name=${INFRA_ID}-bootstrap" | grep "${INFRA_ID}-bootstrap"
then
  echo "$(date -u --rfc-3339=seconds) - Deleting bootstrap deployment..."
  gcloud deployment-manager deployments delete -q "${INFRA_ID}-bootstrap"
fi

# Delete the worker deployment, if exists
if gcloud deployment-manager deployments list --filter="name=${INFRA_ID}-worker" | grep "${INFRA_ID}-worker"
then
  echo "$(date -u --rfc-3339=seconds) - Deleting worker deployment..."
  gcloud deployment-manager deployments delete -q "${INFRA_ID}-worker"
fi

# Delete the control-plane deployment, if exists
if gcloud deployment-manager deployments list --filter="name=${INFRA_ID}-control-plane" | grep "${INFRA_ID}-control-plane"
then
  echo "$(date -u --rfc-3339=seconds) - Deleting control-plane deployment..."
  gcloud deployment-manager deployments delete -q "${INFRA_ID}-control-plane"
fi

# Delete the infra deployment, if exists
if gcloud deployment-manager deployments list --filter="name=${INFRA_ID}-infra" | grep "${INFRA_ID}-infra"
then
  echo "$(date -u --rfc-3339=seconds) - Deleting infra deployment..."
  gcloud deployment-manager deployments delete -q "${INFRA_ID}-infra"
fi

# Delete the firewall deployment, if exists
if gcloud ${project_option} deployment-manager deployments list --filter="name=${INFRA_ID}-firewall" | grep "${INFRA_ID}-firewall"
then
  echo "$(date -u --rfc-3339=seconds) - Deleting firewall deployment..."
  gcloud ${project_option} deployment-manager deployments delete -q "${INFRA_ID}-firewall"
fi

# Delete the IAM deployment, if exists
if gcloud deployment-manager deployments list --filter="name=${INFRA_ID}-iam" | grep "${INFRA_ID}-iam"
then
  echo "$(date -u --rfc-3339=seconds) - Deleting iam deployment..."
  gcloud deployment-manager deployments delete -q "${INFRA_ID}-iam"
fi

if gcloud ${project_option} dns managed-zones list --filter="name~${PRIVATE_ZONE_NAME}" | grep "${PRIVATE_ZONE_NAME}"; then
  # Delete DNS entries
  echo "$(date -u --rfc-3339=seconds) - Deleting DNS type A entries of private zone..."
  if [ -f transaction.yaml ]; then rm transaction.yaml; fi
  gcloud ${project_option} dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
  while read -r line; do
    DNSNAME=$(echo "${line}" | jq -r '.name')
    DNSTTL=$(echo "${line}" | jq -r '.ttl')
    DNSTYPE=$(echo "${line}" | jq -r '.type')
    DNSDATA=$(echo "${line}" | jq -r '.rrdatas[]')
    gcloud ${project_option} dns record-sets transaction remove --zone "${PRIVATE_ZONE_NAME}" --name "${DNSNAME}" --ttl "${DNSTTL}" --type "${DNSTYPE}" "${DNSDATA}"
  done < <(gcloud ${project_option} dns record-sets list --zone="${PRIVATE_ZONE_NAME}" --filter="name:.${CLUSTER_NAME}.${BASE_DOMAIN}." --format=json | jq -c '.[]')

  # Delete the SRV record
  if gcloud dns record-sets list --zone ${PRIVATE_ZONE_NAME} --filter="type~SRV" | grep etcd; then
    echo "$(date -u --rfc-3339=seconds) - Deleting DNS type SRV entries of private zone..."
    gcloud ${project_option} dns record-sets transaction remove \
      --name "_etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type SRV --zone "${PRIVATE_ZONE_NAME}" \
      "0 10 2380 etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}." \
      "0 10 2380 etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}." \
      "0 10 2380 etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}."
    gcloud ${project_option} dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"
  fi
fi

if gcloud ${project_option} dns managed-zones list --filter="name~${BASE_DOMAIN_ZONE_NAME}" | grep "${BASE_DOMAIN_ZONE_NAME}"; then
  echo "$(date -u --rfc-3339=seconds) - Deleting the cluster's DNS type A entries of base domain..."
  if [ -f transaction.yaml ]; then rm transaction.yaml; fi
  gcloud ${project_option} dns record-sets transaction start --zone "${BASE_DOMAIN_ZONE_NAME}"
  while read -r line; do
    DNSNAME=$(echo "${line}" | jq -r '.name')
    DNSTTL=$(echo "${line}" | jq -r '.ttl')
    DNSTYPE=$(echo "${line}" | jq -r '.type')
    DNSDATA=$(echo "${line}" | jq -r '.rrdatas[]')
    gcloud ${project_option} dns record-sets transaction remove --zone "${BASE_DOMAIN_ZONE_NAME}" --name "${DNSNAME}" --ttl "${DNSTTL}" --type "${DNSTYPE}" "${DNSDATA}"
  done < <(gcloud ${project_option} dns record-sets list --zone="${BASE_DOMAIN_ZONE_NAME}" --filter="name:.${CLUSTER_NAME}.${BASE_DOMAIN}." --format=json | jq -c '.[]')
fi

# Delete the DNS deployment, if exists
if gcloud ${project_option} deployment-manager deployments list --filter="name=${INFRA_ID}-dns" | grep "${INFRA_ID}-dns"
then
  echo "$(date -u --rfc-3339=seconds) - Deleting dns deployment..."
  gcloud ${project_option} deployment-manager deployments delete -q "${INFRA_ID}-dns"
fi

# Delete RHCOS image
imagename="${INFRA_ID}-rhcos-image"
if gcloud compute images list --filter="name~${imagename}" | grep "${imagename}"; then
  echo "$(date -u --rfc-3339=seconds) - Deleting the cluster image..."
  gcloud compute images delete -q "${imagename}"
fi
