#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp

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

dir=/tmp/installer
mkdir -p "${dir}"
pushd "${dir}"

if [[ ! -s "${SHARED_DIR}/metadata.json" ]]; then
  echo "Skipping: ${SHARED_DIR}/metadata.json not found."
  exit
fi
BASE_DOMAIN="$(cat ${CLUSTER_PROFILE_DIR}/public_hosted_zone)"
BASE_DOMAIN_ZONE_NAME="$(gcloud dns managed-zones list --filter "DNS_NAME=${BASE_DOMAIN}." --format json | jq -r .[0].name)"
CLUSTER_NAME="$(jq -r .clusterName "${SHARED_DIR}/metadata.json")"
INFRA_ID="$(jq -r .infraID "${SHARED_DIR}/metadata.json")"
PRIVATE_ZONE_NAME="${INFRA_ID}-private-zone"

### Read XPN config, if exists
PROJECT_OPTION=""
if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  echo "Reading variables from ${SHARED_DIR}/xpn.json..."
  IS_XPN=1
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_PRIVATE_ZONE_NAME="$(jq -r '.privateZoneName' "${SHARED_DIR}/xpn.json")"
  PRIVATE_ZONE_NAME=${HOST_PROJECT_PRIVATE_ZONE_NAME}
  HOST_PROJECT_CONTROL_SERVICE_ACCOUNT="$(jq -r '.controlServiceAccount' "${SHARED_DIR}/xpn.json")"

  if [[ -n "${GOOGLE_CLOUD_XPN_SA}" ]]; then
    echo "Using XPN configurations..."
    PROJECT_OPTION="--project ${HOST_PROJECT} --account ${GOOGLE_CLOUD_XPN_SA}"
  else
    PROJECT_OPTION="--project ${HOST_PROJECT}"
  fi
fi

# Delete XPN service account key
if [[ -v IS_XPN ]] && [[ -f "${SHARED_DIR}/xpn_sa_key_id" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Deleting the XPN service account key..."
  gcloud iam service-accounts keys delete -q "$(< ${SHARED_DIR}/xpn_sa_key_id)" --iam-account="${HOST_PROJECT_CONTROL_SERVICE_ACCOUNT}"
  gcloud iam service-accounts keys list --iam-account="${HOST_PROJECT_CONTROL_SERVICE_ACCOUNT}"
fi

# Delete the bootstrap deployment, but expect it to error.
echo "$(date -u --rfc-3339=seconds) - Deleting bootstrap deployment (errors when bootstrap-complete)..."
set +e
gcloud deployment-manager deployments delete -q "${INFRA_ID}-bootstrap"
set -e

# Delete XPN DNS entries
set +e
gcloud ${PROJECT_OPTION} dns record-sets list --zone="${PRIVATE_ZONE_NAME}" --filter="name:.${CLUSTER_NAME}.${BASE_DOMAIN}."
gcloud dns record-sets list --zone="${BASE_DOMAIN_ZONE_NAME}" --filter="name:.${CLUSTER_NAME}.${BASE_DOMAIN}."

echo "$(date -u --rfc-3339=seconds) - Deleting DNS record-sets of private zone..."
if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud ${PROJECT_OPTION} dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
while read -r line; do
  DNSNAME=$(echo "${line}" | jq -r '.name')
  DNSTTL=$(echo "${line}" | jq -r '.ttl')
  DNSTYPE=$(echo "${line}" | jq -r '.type')
  DNSDATA=$(echo "${line}" | jq -r '.rrdatas[]')
  gcloud ${PROJECT_OPTION} dns record-sets transaction remove --zone "${PRIVATE_ZONE_NAME}" --name "${DNSNAME}" --ttl "${DNSTTL}" --type "${DNSTYPE}" "${DNSDATA}"
done < <(gcloud ${PROJECT_OPTION} dns record-sets list --zone="${PRIVATE_ZONE_NAME}" --filter="name:.${CLUSTER_NAME}.${BASE_DOMAIN}." --format=json | jq -c '.[]')
gcloud ${PROJECT_OPTION} dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"

echo "$(date -u --rfc-3339=seconds) - Deleting DNS record-sets of base domain..."
if [ -f transaction.yaml ]; then rm transaction.yaml; fi
gcloud dns record-sets transaction start --zone "${BASE_DOMAIN_ZONE_NAME}"
while read -r line; do
  DNSNAME=$(echo "${line}" | jq -r '.name')
  DNSTTL=$(echo "${line}" | jq -r '.ttl')
  DNSTYPE=$(echo "${line}" | jq -r '.type')
  DNSDATA=$(echo "${line}" | jq -r '.rrdatas[]')
  gcloud dns record-sets transaction remove --zone "${BASE_DOMAIN_ZONE_NAME}" --name "${DNSNAME}" --ttl "${DNSTTL}" --type "${DNSTYPE}" "${DNSDATA}"
done < <(gcloud dns record-sets list --zone="${BASE_DOMAIN_ZONE_NAME}" --filter="name:.${CLUSTER_NAME}.${BASE_DOMAIN}." --format=json | jq -c '.[]')
gcloud dns record-sets transaction execute --zone "${BASE_DOMAIN_ZONE_NAME}"

if [[ -v IS_XPN ]]; then
  if [ -f transaction.yaml ]; then rm transaction.yaml; fi
  gcloud ${PROJECT_OPTION} dns record-sets transaction start --zone "${PRIVATE_ZONE_NAME}"
  # Delete the SRV record
  gcloud ${PROJECT_OPTION} dns record-sets transaction remove \
    --name "_etcd-server-ssl._tcp.${CLUSTER_NAME}.${BASE_DOMAIN}." --ttl 60 --type SRV --zone "${PRIVATE_ZONE_NAME}" \
    "0 10 2380 etcd-0.${CLUSTER_NAME}.${BASE_DOMAIN}." \
    "0 10 2380 etcd-1.${CLUSTER_NAME}.${BASE_DOMAIN}." \
    "0 10 2380 etcd-2.${CLUSTER_NAME}.${BASE_DOMAIN}."
  gcloud ${PROJECT_OPTION} dns record-sets transaction execute --zone "${PRIVATE_ZONE_NAME}"
fi
set -e

# Delete the deployments that should always exist.
echo "$(date -u --rfc-3339=seconds) - Deleting worker, control-plane, and infra deployments..."
gcloud deployment-manager deployments delete -q "${INFRA_ID}"-{worker,control-plane,infra}

# Only delete these deployments when they are expected to exist.
if [[ ! -v IS_XPN ]]; then
  echo "$(date -u --rfc-3339=seconds) - Deleting security deployment..."
  gcloud deployment-manager deployments delete -q "${INFRA_ID}-security"

  if [[ ! -f "${SHARED_DIR}/customer_vpc_subnets.yaml" ]]; then
    echo "$(date -u --rfc-3339=seconds) - Deleting vpc deployment..."
    gcloud deployment-manager deployments delete -q "${INFRA_ID}-vpc"
  fi
fi
