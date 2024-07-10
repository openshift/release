#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

function queue() {
  local LIVE="$(jobs | wc -l)"
  while [[ "${LIVE}" -ge 10 ]]; do
    sleep 1
    LIVE="$(jobs | wc -l)"
  done
  echo "${@}"
  "${@}" &
}

function deprovision() {
  WORKDIR="${1}"
  timeout --signal=SIGQUIT 30m openshift-install --dir "${WORKDIR}" --log-level error destroy cluster && touch "${WORKDIR}/success" || touch "${WORKDIR}/failure"
}

logdir="${ARTIFACTS}/deprovision"
mkdir -p "${logdir}"


gce_cluster_age_cutoff="$(TZ=":America/Los_Angeles" date --date="${CLUSTER_TTL}-8 hours" '+%Y-%m-%dT%H:%M%z')"
echo "deprovisioning clusters with a creationTimestamp before ${gce_cluster_age_cutoff} in GCE ..."
export CLOUDSDK_CONFIG=/tmp/gcloudconfig
mkdir -p "${CLOUDSDK_CONFIG}"
gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"

echo "GCP project: ${GCP_PROJECT}"

export FILTER="creationTimestamp.date('%Y-%m-%dT%H:%M%z')<${gce_cluster_age_cutoff} AND autoCreateSubnetworks=false AND name~'ci-'"
for network in $( gcloud --project="${GCP_PROJECT}" compute networks list --filter "${FILTER}" --format "value(name)" ); do
  infraID="${network%"-network"}"
  region="$( gcloud --project="${GCP_PROJECT}" compute networks describe "${network}" --format="value(subnetworks[0])" | grep -Po "(?<=regions/)[^/]+" || true )"
  if [[ -z "${region:-}" ]]; then
    region=us-east1
  fi
  workdir="${logdir}/${infraID}"
  mkdir -p "${workdir}"
  cat <<EOF >"${workdir}/metadata.json"
{
  "infraID":"${infraID}",
  "gcp":{
    "region":"${region}",
    "projectID":"${GCP_PROJECT}"
  }
}
EOF
  echo "will deprovision GCE cluster ${infraID} in region ${region}"
done

clusters=$( find "${logdir}" -mindepth 1 -type d )
for workdir in $(shuf <<< ${clusters}); do
  queue deprovision "${workdir}"
done

wait

gcs_bucket_age_cutoff="$(TZ="GMT" date --date="${CLUSTER_TTL}-8 hours" '+%a, %d %b %Y %H:%M:%S GMT')"
gcs_bucket_age_cutoff_seconds="$(date --date="${gcs_bucket_age_cutoff}" '+%s')"
echo "deleting GCS buckets with a creationTimestamp before ${gcs_bucket_age_cutoff} in GCE ..."
BUCKET_DATA="$(gsutil -m ls -p "${GCP_PROJECT}" -L -b 'gs://ci-op-*')"
printf "got %d characters of bucket listing output\n" "${#BUCKET_DATA}"
buckets=()
if [[ "${#BUCKET_DATA}" -gt 0 ]]; then
  while read -r bucket; do
    read -r creationTime
    if [[ ${gcs_bucket_age_cutoff_seconds} -ge $( date --date="${creationTime}" '+%s' ) ]]; then
      buckets+=("${bucket}")
    fi
  done <<< $( printf '%s' "${BUCKET_DATA}" | grep -Po "(gs:[^ ]+)|(?<=Time created:).*" )
fi
echo "found ${#buckets[@]} old buckets"
if [[ "${#buckets[@]}" -gt 0 ]]; then
  timeout 30m gsutil -m rm -r "${buckets[@]}"
fi

# Prune Filestore instances
export FILESTORE_FILTER="createTime.date('%Y-%m-%dT%H:%M%z')<${gce_cluster_age_cutoff} AND name~'-ci'"
INSTANCES=$( gcloud --project="${GCP_PROJECT}" filestore instances list --filter "${FILESTORE_FILTER}" --uri )
for INSTANCE in $INSTANCES; do
    echo "Deleting Filestore instance $INSTANCE"
    gcloud filestore instances delete "$INSTANCE" --async --force --quiet
done

FAILED="$(find ${clusters} -name failure -printf '%H\n' | sort)"
if [[ -n "${FAILED}" ]]; then
  echo "Deprovision failed on the following clusters:"
  xargs --max-args 1 basename <<< $FAILED
  exit 1
fi

echo "Deprovision finished successfully"
