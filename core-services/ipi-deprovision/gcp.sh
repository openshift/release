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
  timeout --signal=SIGTERM 20m openshift-install --dir "${WORKDIR}" --log-level error destroy cluster && touch "${WORKDIR}/success" || touch "${WORKDIR}/failure"
}

function cleanup_vpc_network() {
  local infraID="${1}"
  local networkLink
  networkLink="$(gcloud --project="${GCP_PROJECT}" compute networks describe "${infraID}-network" --format="value(selfLink)")" || return 1

  for rule in $(gcloud --project="${GCP_PROJECT}" compute forwarding-rules list --filter="network=${networkLink}" --format="csv[no-heading](name,region.basename())"); do
    rule_name="${rule%%,*}"
    rule_region="${rule##*,}"
    if [[ -n "${rule_region}" ]]; then
      echo "Deleting forwarding rule ${rule_name} in ${rule_region} ..."
      gcloud --project="${GCP_PROJECT}" compute forwarding-rules delete "${rule_name}" --region="${rule_region}" --quiet || return 1
    else
      echo "Deleting global forwarding rule ${rule_name} ..."
      gcloud --project="${GCP_PROJECT}" compute forwarding-rules delete "${rule_name}" --global --quiet || return 1
    fi
  done

  for fw in $(gcloud --project="${GCP_PROJECT}" compute firewall-rules list --filter="network=${networkLink}" --format="value(name)"); do
    echo "Deleting firewall rule ${fw} ..."
    gcloud --project="${GCP_PROJECT}" compute firewall-rules delete "${fw}" --quiet || return 1
  done

  for subnet_info in $(gcloud --project="${GCP_PROJECT}" compute networks subnets list --filter="network=${networkLink}" --format="csv[no-heading](name,region.basename())"); do
    subnet_name="${subnet_info%%,*}"
    subnet_region="${subnet_info##*,}"
    echo "Deleting subnet ${subnet_name} in ${subnet_region} ..."
    gcloud --project="${GCP_PROJECT}" compute networks subnets delete "${subnet_name}" --region="${subnet_region}" --quiet || return 1
  done

  for route in $(gcloud --project="${GCP_PROJECT}" compute routes list --filter="network=${networkLink}" --format="value(name)"); do
    echo "Deleting route ${route} ..."
    gcloud --project="${GCP_PROJECT}" compute routes delete "${route}" --quiet || return 1
  done

  gcloud --project="${GCP_PROJECT}" compute networks delete "${infraID}-network" --quiet || return 1
}

function delete_service_account() {
  local service_account="${1}"
  echo "Deleting IAM service account ${service_account} ..."
  gcloud iam service-accounts delete -q "${service_account}" --project="${GCP_PROJECT}"
}

function service_account_is_active() {
  local sa_id="${1}" sa_display="${2}" active_ids_file="${3}"
  local active_id
  while read -r active_id; do
    [[ -z "${active_id}" ]] && continue
    if [[ "${sa_id}" == "${active_id}" || "${sa_id}" == "${active_id}-"* \
      || "${sa_display}" == "${active_id}" || "${sa_display}" == "${active_id}-"* ]]; then
      return 0
    fi
  done < "${active_ids_file}"
  return 1
}

function service_account_is_prunable() {
  local sa_id="${1}" sa_display="${2}"
  [[ "${sa_id}" == ci-provision* || "${sa_display}" == ci-provision* ]] && return 1
  [[ "${sa_id}" == do-not-delete-* || "${sa_display}" == do-not-delete-* ]] && return 1
  [[ "${sa_id}" == ci-op-* || "${sa_display}" == ci-op-* ]] && return 0
  [[ "${sa_id}" =~ ^ci-[0-9a-z]{4,}- || "${sa_display}" =~ ^ci-[0-9a-z]{4,}- ]] && return 0
  return 1
}

function cleanup_orphaned_service_accounts() {
  local active_ids_file sa_json_file sa_list_file sa_filter orphaned_count=0 failed=0 provisioner_email=""
  active_ids_file="$(mktemp)"
  sa_json_file="$(mktemp)"
  sa_list_file="$(mktemp)"

  if [[ -f "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
    provisioner_email="$(jq -r '.client_email // empty' "${GOOGLE_APPLICATION_CREDENTIALS}")"
  fi

  if ! gcloud --project="${GCP_PROJECT}" compute networks list \
    --filter "autoCreateSubnetworks=false AND name~'ci-'" \
    --format 'value(name)' | sed 's/-network$//' >"${active_ids_file}"; then
    rm -f "${active_ids_file}" "${sa_json_file}" "${sa_list_file}"
    return 1
  fi

  echo "pruning orphaned IAM service accounts with a createTime before ${gce_cluster_age_cutoff} ..."
  sa_filter="email~'^ci-op-.*' OR email~'^ci-[0-9a-z]{4,}-.*'"
  if ! gcloud --project="${GCP_PROJECT}" iam service-accounts list \
    --filter "${sa_filter}" --format=json >"${sa_json_file}"; then
    rm -f "${active_ids_file}" "${sa_json_file}" "${sa_list_file}"
    return 1
  fi
  if ! jq -r --argjson cutoff "${gce_cluster_age_cutoff_seconds}" \
    '.[] | select(.createTime != null) | select((.createTime | sub("\\.[0-9]+"; "") | fromdateiso8601) < $cutoff) | [.email, (.displayName // "")] | @tsv' \
    "${sa_json_file}" >"${sa_list_file}"; then
    rm -f "${active_ids_file}" "${sa_json_file}" "${sa_list_file}"
    return 1
  fi

  while IFS=$'\t' read -r sa_email sa_display; do
    [[ -z "${sa_email}" ]] && continue
    [[ -n "${provisioner_email}" && "${sa_email}" == "${provisioner_email}" ]] && continue
    local sa_id="${sa_email%%@*}"
    if ! service_account_is_prunable "${sa_id}" "${sa_display}"; then
      continue
    fi
    if service_account_is_active "${sa_id}" "${sa_display}" "${active_ids_file}"; then
      continue
    fi
    if delete_service_account "${sa_email}"; then
      orphaned_count=$((orphaned_count + 1))
    else
      echo "Failed to delete orphaned IAM service account ${sa_email}"
      failed=1
    fi
  done < "${sa_list_file}"
  echo "deleted ${orphaned_count} orphaned IAM service account(s)"
  rm -f "${active_ids_file}" "${sa_json_file}" "${sa_list_file}"
  return "${failed}"
}

logdir="${ARTIFACTS}/deprovision"
mkdir -p "${logdir}"


gce_cluster_age_cutoff="$(TZ=":America/Los_Angeles" date --date="${CLUSTER_TTL}-8 hours" '+%Y-%m-%dT%H:%M%z')"
gce_cluster_age_cutoff_seconds="$(TZ=":America/Los_Angeles" date --date="${CLUSTER_TTL}-8 hours" '+%s')"
echo "deprovisioning clusters with a creationTimestamp before ${gce_cluster_age_cutoff} in GCE ..."
export CLOUDSDK_CONFIG=/tmp/gcloudconfig
mkdir -p "${CLOUDSDK_CONFIG}"
gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"

echo "GCP project: ${GCP_PROJECT}"

if [[ -n "${GCP_ORPHAN_SA_ONLY:-}" ]]; then
  cleanup_orphaned_service_accounts
  exit $?
fi

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

# log installer version for debugging purposes
openshift-install version

clusters=$( find "${logdir}" -mindepth 1 -type d )
for workdir in $(shuf <<< ${clusters}); do
  queue deprovision "${workdir}"
done

if ! wait; then
  echo "At least one deprovision job failed or timed out."
fi

for workdir in $(find "${logdir}" -mindepth 1 -type d); do
  if [[ -f "${workdir}/failure" ]]; then
    infraID="$(basename "${workdir}")"
    echo "Attempting to clean up VPC network ${infraID}-network ..."
    if cleanup_vpc_network "${infraID}"; then
      echo "Successfully deleted VPC network for ${infraID}"
      rm "${workdir}/failure"
      touch "${workdir}/warning"
    else
      echo "Failed to clean up VPC network for ${infraID}"
    fi
  fi
done

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

cleanup_orphaned_service_accounts

WARNINGS="$(find ${clusters} -name warning -printf '%H\n' | sort)"
if [[ -n "${WARNINGS}" ]]; then
  echo "The following clusters required VPC network cleanup:"
  xargs --max-args 1 basename <<< $WARNINGS
fi

FAILED="$(find ${clusters} -name failure -printf '%H\n' | sort)"
if [[ -n "${FAILED}" ]]; then
  echo "Deprovision failed on the following clusters:"
  xargs --max-args 1 basename <<< $FAILED
  exit 1
fi

echo "Deprovision finished successfully"
