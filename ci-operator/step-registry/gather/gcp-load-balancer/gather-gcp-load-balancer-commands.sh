#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
UNIVERSE_DOMAIN=$(jq -r ".universe_domain // empty" "${GOOGLE_CLOUD_KEYFILE_JSON}" 2>/dev/null)
if [[ -n "${UNIVERSE_DOMAIN}" ]]; then
  export GOOGLE_CLOUD_UNIVERSE_DOMAIN="${UNIVERSE_DOMAIN}"
  gcloud config set universe_domain "${UNIVERSE_DOMAIN}"
fi
gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"

if test ! -f "${SHARED_DIR}/metadata.json"
then
	echo "No metadata.json, so unknown GCP project and infra ID, so unable to gather load balancer data."
	exit 0
fi

PROJECT_ID="$(jq -r '.gcp.projectID' "${SHARED_DIR}/metadata.json")"
INFRA_ID="$(jq -r '.infraID' "${SHARED_DIR}/metadata.json")"
REGION="$(jq -r '.gcp.region' "${SHARED_DIR}/metadata.json")"

if [[ -z "${PROJECT_ID}" || "${PROJECT_ID}" == "null" ]]; then
	echo "Could not determine GCP project ID from metadata.json."
	exit 0
fi

if [[ -z "${INFRA_ID}" || "${INFRA_ID}" == "null" ]]; then
	echo "Could not determine infrastructure ID from metadata.json."
	exit 0
fi

if [[ -z "${REGION}" || "${REGION}" == "null" ]]; then
	echo "Could not determine GCP region from metadata.json."
	exit 0
fi

gcloud config set project "${PROJECT_ID}"

# while gathering data from a private cluster, proxy setting is required for connecting cluster
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	echo "Going to enable client proxy by 'source ${SHARED_DIR}/proxy-conf.sh'"
	source "${SHARED_DIR}/proxy-conf.sh"
else
	echo "No '${SHARED_DIR}/proxy-conf.sh' found, skip enabling client proxy."
fi

OUTPUT_DIR="${ARTIFACT_DIR}/gcp-load-balancer"
mkdir -p "${OUTPUT_DIR}"

echo "Gathering GCP load balancer resources for infra ID '${INFRA_ID}' in project '${PROJECT_ID}', region '${REGION}'..."

# From here on, do not exit on individual command failures so we can
# collect as much data as possible.
set +o errexit

# Run a gcloud command, write its JSON output to a file, and print the output
# to stdout on success. On failure, writes a JSON error object instead.
gcloud_json() {
  local output_file="$1"
  shift
  local output
  output=$("$@" 2>/dev/null)
  local rc=$?
  if [[ ${rc} -ne 0 ]]; then
    printf '{"error":"command failed","exit_code":%d}\n' "${rc}" > "${output_file}"
  else
    printf '%s\n' "${output}" > "${output_file}"
    printf '%s\n' "${output}"
  fi
  return ${rc}
}

#
# Forwarding rules (regional and global)
#
echo "Collecting forwarding rules..."
FORWARDING_RULES=$(gcloud_json "${OUTPUT_DIR}/forwarding-rules-list.json" \
  gcloud compute forwarding-rules list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --format=json) || FORWARDING_RULES="[]"

if [[ -n "${FORWARDING_RULES}" && "${FORWARDING_RULES}" != "[]" ]]; then
  while IFS= read -r rule_name; do
    # .region is a full resource URL; extract the trailing region name
    rule_region_url=$(echo "${FORWARDING_RULES}" | jq -r ".[] | select(.name==\"${rule_name}\") | .region // empty")
    if [[ -n "${rule_region_url}" ]]; then
      gcloud_json "${OUTPUT_DIR}/forwarding-rule-${rule_name}.json" \
        gcloud compute forwarding-rules describe "${rule_name}" \
        --project="${PROJECT_ID}" \
        --region="$(basename "${rule_region_url}")" \
        --format=json
    else
      gcloud_json "${OUTPUT_DIR}/forwarding-rule-${rule_name}.json" \
        gcloud compute forwarding-rules describe "${rule_name}" \
        --project="${PROJECT_ID}" \
        --global \
        --format=json
    fi
  done < <(echo "${FORWARDING_RULES}" | jq -r '.[].name')
fi

#
# Target pools (regional)
#
echo "Collecting target pools..."
TARGET_POOLS=$(gcloud_json "${OUTPUT_DIR}/target-pools-list.json" \
  gcloud compute target-pools list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --regions="${REGION}" \
  --format=json) || TARGET_POOLS="[]"

if [[ -n "${TARGET_POOLS}" && "${TARGET_POOLS}" != "[]" ]]; then
  while IFS= read -r pool_name; do
    gcloud_json "${OUTPUT_DIR}/target-pool-${pool_name}.json" \
      gcloud compute target-pools describe "${pool_name}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --format=json

    gcloud_json "${OUTPUT_DIR}/target-pool-health-${pool_name}.json" \
      gcloud compute target-pools get-health "${pool_name}" \
      --project="${PROJECT_ID}" \
      --region="${REGION}" \
      --format=json
  done < <(echo "${TARGET_POOLS}" | jq -r '.[].name')
fi

#
# Backend services (regional and global)
#
echo "Collecting backend services..."
BACKEND_SERVICES=$(gcloud_json "${OUTPUT_DIR}/backend-services-list.json" \
  gcloud compute backend-services list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --format=json) || BACKEND_SERVICES="[]"

if [[ -n "${BACKEND_SERVICES}" && "${BACKEND_SERVICES}" != "[]" ]]; then
  while IFS= read -r bs_name; do
    bs_region_url=$(echo "${BACKEND_SERVICES}" | jq -r ".[] | select(.name==\"${bs_name}\") | .region // empty")
    if [[ -n "${bs_region_url}" ]]; then
      gcloud_json "${OUTPUT_DIR}/backend-service-${bs_name}.json" \
        gcloud compute backend-services describe "${bs_name}" \
        --project="${PROJECT_ID}" \
        --region="$(basename "${bs_region_url}")" \
        --format=json

      gcloud_json "${OUTPUT_DIR}/backend-service-health-${bs_name}.json" \
        gcloud compute backend-services get-health "${bs_name}" \
        --project="${PROJECT_ID}" \
        --region="$(basename "${bs_region_url}")" \
        --format=json
    else
      gcloud_json "${OUTPUT_DIR}/backend-service-${bs_name}.json" \
        gcloud compute backend-services describe "${bs_name}" \
        --project="${PROJECT_ID}" \
        --global \
        --format=json

      gcloud_json "${OUTPUT_DIR}/backend-service-health-${bs_name}.json" \
        gcloud compute backend-services get-health "${bs_name}" \
        --project="${PROJECT_ID}" \
        --global \
        --format=json
    fi
  done < <(echo "${BACKEND_SERVICES}" | jq -r '.[].name')
fi

#
# Health checks (regional and global)
#
echo "Collecting health checks..."
HEALTH_CHECKS=$(gcloud_json "${OUTPUT_DIR}/health-checks-list.json" \
  gcloud compute health-checks list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --format=json) || HEALTH_CHECKS="[]"

if [[ -n "${HEALTH_CHECKS}" && "${HEALTH_CHECKS}" != "[]" ]]; then
  while IFS= read -r hc_name; do
    hc_region_url=$(echo "${HEALTH_CHECKS}" | jq -r ".[] | select(.name==\"${hc_name}\") | .region // empty")
    if [[ -n "${hc_region_url}" ]]; then
      gcloud_json "${OUTPUT_DIR}/health-check-${hc_name}.json" \
        gcloud compute health-checks describe "${hc_name}" \
        --project="${PROJECT_ID}" \
        --region="$(basename "${hc_region_url}")" \
        --format=json
    else
      gcloud_json "${OUTPUT_DIR}/health-check-${hc_name}.json" \
        gcloud compute health-checks describe "${hc_name}" \
        --project="${PROJECT_ID}" \
        --global \
        --format=json
    fi
  done < <(echo "${HEALTH_CHECKS}" | jq -r '.[].name')
fi

#
# Firewall rules
#
echo "Collecting firewall rules..."
gcloud_json "${OUTPUT_DIR}/firewall-rules-list.json" \
  gcloud compute firewall-rules list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --format=json

#
# Target TCP/SSL/HTTPS proxies (global, if any)
#
echo "Collecting target TCP proxies..."
gcloud_json "${OUTPUT_DIR}/target-tcp-proxies-list.json" \
  gcloud compute target-tcp-proxies list \
  --project="${PROJECT_ID}" \
  --filter="name~^${INFRA_ID}" \
  --format=json

#
# Cloud Logging: load-balancer-related log entries (best effort, limited)
#
echo "Collecting load balancer log entries from Cloud Logging..."
gcloud_json "${OUTPUT_DIR}/lb-log-entries.json" \
  gcloud logging read \
  "(resource.type=\"gce_forwarding_rule\" OR resource.type=\"http_load_balancer\" OR resource.type=\"tcp_ssl_proxy_rule\" OR resource.type=\"network_tcp_ssl_proxy_rule\") ) AND resource.labels.name=~\"^${INFRA_ID}\"" \
  --project="${PROJECT_ID}" \
  --limit=200 \
  --freshness=3h \
  --format=json

echo "GCP load balancer resource gathering complete. Output written to ${OUTPUT_DIR}/"
