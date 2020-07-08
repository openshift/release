#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"
gcloud config set project "$(jq -r .gcp.projectID "${SHARED_DIR}/metadata.json")"

dir=/tmp/installer
mkdir -p "${dir}"
pushd "${dir}"

if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi
BASE_DOMAIN='origin-ci-int-gce.dev.openshift.com'
CLUSTER_NAME="$(jq -r .clusterName "${SHARED_DIR}/metadata.json")"
INFRA_ID="$(jq -r .infraID "${SHARED_DIR}/metadata.json")"

### Read XPN config, if exists
if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  echo "Reading variables from ${SHARED_DIR}/xpn.json..."
  IS_XPN=1
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_PRIVATE_ZONE_NAME="$(jq -r '.privateZoneName' "${SHARED_DIR}/xpn.json")"
fi

# Delete the bootstrap deployment, but expect it to error.
echo "$(date -u --rfc-3339=seconds) - Deleting bootstrap deployment (errors when bootstrap-complete)..."
set +e
gcloud deployment-manager deployments delete -q "${INFRA_ID}-bootstrap"
set -e

# Delete the deployments that should always exist.
echo "$(date -u --rfc-3339=seconds) - Deleting worker, control-plane, and infra deployments..."
gcloud deployment-manager deployments delete -q "${INFRA_ID}"-{worker,control-plane,infra}

# Only delete these deployments when they are expected to exist.
if [[ ! -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Deleting security and vpc deployments..."
  gcloud deployment-manager deployments delete -q "${INFRA_ID}"-{security,vpc}
fi

# Delete XPN DNS entries
if [[ -v IS_XPN ]]; then
  set +e
  if [ -f transaction.yaml ]; then rm transaction.yaml; fi
  gcloud --project="${HOST_PROJECT}" dns record-sets transaction start --zone "${HOST_PROJECT_PRIVATE_ZONE_NAME}"
  while read -r line; do
    DNSNAME=$(echo "${line}" | jq -r '.name')
    DNSTTL=$(echo "${line}" | jq -r '.ttl')
    DNSTYPE=$(echo "${line}" | jq -r '.type')
    DNSDATA=$(echo "${line}" | jq -r '.rrdatas[]')
    gcloud --project="${HOST_PROJECT}" dns record-sets transaction remove --zone "${HOST_PROJECT_PRIVATE_ZONE_NAME}" --name "${DNSNAME}" --ttl "${DNSTTL}" --type "${DNSTYPE}" "${DNSDATA}"
  done < <(gcloud --project="${HOST_PROJECT}" dns record-sets list --zone="${HOST_PROJECT_PRIVATE_ZONE_NAME}" --filter="name:.${CLUSTER_NAME}.${BASE_DOMAIN}." --format=json | jq -c '.[]')
  # Delete the SRV record
  gcloud "--project=${HOST_PROJECT}" dns record-sets transaction remove \
    --name "_etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type SRV --zone "${HOST_PROJECT_PRIVATE_ZONE_NAME}" \
    "0 10 2380 etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}." \
    "0 10 2380 etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}." \
    "0 10 2380 etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}."
  gcloud --project="${HOST_PROJECT}" dns record-sets transaction execute --zone "${HOST_PROJECT_PRIVATE_ZONE_NAME}"
  set -e
fi
