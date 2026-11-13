#!/bin/bash

set -euo pipefail

idle_timeout="${IBMCLOUD_INGRESS_IDLE_TIMEOUT:-}"
if [[ -z "${idle_timeout}" ]]; then
  echo "IBMCLOUD_INGRESS_IDLE_TIMEOUT is empty; keeping the cloud default."
  exit 0
fi
if [[ ! "${idle_timeout}" =~ ^[1-9][0-9]{1,3}$ ]] ||
  (( idle_timeout < 50 || idle_timeout > 7200 )); then
  echo "ERROR: IBMCLOUD_INGRESS_IDLE_TIMEOUT must be an integer from 50 to 7200." >&2
  exit 1
fi

region="${LEASED_RESOURCE:?LEASED_RESOURCE must identify the IBM Cloud region}"
region="${region%%--*}"
if [[ ! "${region}" =~ ^[a-z][a-z0-9-]+$ ]]; then
  echo "ERROR: invalid IBM Cloud region." >&2
  exit 1
fi
api_key_file="${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
if [[ ! -s "${api_key_file}" ]]; then
  echo "ERROR: the cluster profile is missing ibmcloud-api-key." >&2
  exit 1
fi

umask 077
work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

# Keep the API key and IAM token in private temporary files, outside artifacts.
tr -d '\r\n' < "${api_key_file}" > "${work_dir}/api-key"
curl --fail --silent --show-error --connect-timeout 10 --max-time 60 \
  --retry 2 --retry-delay 2 \
  --request POST 'https://iam.cloud.ibm.com/identity/token' \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=urn:ibm:params:oauth:grant-type:apikey' \
  --data-urlencode "apikey@${work_dir}/api-key" \
  --output "${work_dir}/iam.json"
jq -er '.access_token | select(type == "string" and length > 0)
  | "header = \"Authorization: Bearer " + . + "\""' \
  "${work_dir}/iam.json" > "${work_dir}/auth.conf"

vpc_endpoint="https://${region}.iaas.cloud.ibm.com"
api_query='version=2025-06-30&generation=2'

function vpc_request() {
  local method="$1" url="$2" output="$3"
  local -a args=(
    --fail --silent --show-error --connect-timeout 10 --max-time 30
    --retry 2 --retry-delay 2 --config "${work_dir}/auth.conf"
    --header 'Content-Type: application/json'
    --request "${method}" --output "${output}"
  )
  if [[ "$#" -eq 4 ]]; then
    args+=(--data-binary "@$4")
  fi
  curl "${args[@]}" "${url}"
}

export KUBECONFIG="${SHARED_DIR}/kubeconfig"
router_hostname=""
for _ in {1..30}; do
  router_hostname="$(oc --request-timeout=10s -n openshift-ingress get service router-default \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "${router_hostname}" ]] && break
  sleep 10
done
if [[ -z "${router_hostname}" ]]; then
  echo "ERROR: router-default has no load balancer hostname." >&2
  exit 1
fi

# Follow pagination: the ingress load balancer need not be on the first page.
next_url="${vpc_endpoint}/v1/load_balancers?${api_query}&limit=100"
lb_id=""
for _ in {1..100}; do
  # Do not forward the IAM token to a different endpoint from a pagination link.
  if [[ "${next_url}" != "${vpc_endpoint}/v1/load_balancers?"* ]]; then
    echo "ERROR: unexpected VPC load balancer pagination URL." >&2
    exit 1
  fi
  vpc_request GET "${next_url}" "${work_dir}/load-balancers.json"
  jq -r --arg hostname "${router_hostname}" \
    '.load_balancers[] | select(.hostname == $hostname) | .id' \
    "${work_dir}/load-balancers.json" > "${work_dir}/matches"
  mapfile -t matches < "${work_dir}/matches"
  if [[ "${#matches[@]}" -gt 1 ]]; then
    echo "ERROR: multiple load balancers match router-default." >&2
    exit 1
  fi
  if [[ "${#matches[@]}" -eq 1 ]]; then
    lb_id="${matches[0]}"
    break
  fi
  next_url="$(jq -r '.next.href // empty' "${work_dir}/load-balancers.json")"
  [[ -n "${next_url}" ]] || break
done
if [[ ! "${lb_id}" =~ ^[a-zA-Z0-9-]+$ ]]; then
  echo "ERROR: could not identify the ingress load balancer." >&2
  exit 1
fi

vpc_request GET "${vpc_endpoint}/v1/load_balancers/${lb_id}/listeners?${api_query}" "${work_dir}/listeners.json"
jq -r '.listeners[]
  | select(.port == 443 or (.port_min == 443 and .port_max == 443)) | .id' \
  "${work_dir}/listeners.json" > "${work_dir}/listener-ids"
mapfile -t listeners < "${work_dir}/listener-ids"
if [[ "${#listeners[@]}" -ne 1 || ! "${listeners[0]}" =~ ^[a-zA-Z0-9-]+$ ]]; then
  echo "ERROR: expected exactly one ingress listener for port 443." >&2
  exit 1
fi
listener_url="${vpc_endpoint}/v1/load_balancers/${lb_id}/listeners/${listeners[0]}?${api_query}"

function wait_for_listener() {
  local expected="$1" status actual
  for _ in {1..30}; do
    vpc_request GET "${listener_url}" "${work_dir}/listener.json"
    status="$(jq -er '.provisioning_status' "${work_dir}/listener.json")"
    actual="$(jq -r '.idle_connection_timeout // empty' "${work_dir}/listener.json")"
    if [[ "${status}" == active && ( -z "${expected}" || "${actual}" == "${expected}" ) ]]; then
      return 0
    fi
    if [[ "${status}" == failed || "${status}" == delete_pending ]]; then
      echo "ERROR: ingress listener is in state ${status}." >&2
      return 1
    fi
    sleep 10
  done
  echo "ERROR: timed out waiting for the ingress listener configuration." >&2
  return 1
}

wait_for_listener ""
previous_timeout="$(jq -r '.idle_connection_timeout // null' "${work_dir}/listener.json")"
if [[ "${previous_timeout}" != "${idle_timeout}" ]]; then
  jq -n --argjson timeout "${idle_timeout}" '{idle_connection_timeout: $timeout}' > "${work_dir}/patch.json"
  vpc_request PATCH "${listener_url}" "${work_dir}/update.json" "${work_dir}/patch.json"
  wait_for_listener "${idle_timeout}"
fi

mkdir -p "${ARTIFACT_DIR}"
jq -n --arg load_balancer_id "${lb_id}" --arg listener_id "${listeners[0]}" \
  --arg region "${region}" --argjson previous_timeout "${previous_timeout}" \
  --argjson timeout "${idle_timeout}" \
  '{region: $region, load_balancer_id: $load_balancer_id, listener_id: $listener_id,
    port: 443, previous_idle_timeout_seconds: $previous_timeout,
    idle_timeout_seconds: $timeout, provisioning_status: "active"}' \
  > "${ARTIFACT_DIR}/ibmcloud-ingress-timeout.json"
echo "Verified ingress HTTPS listener idle timeout: ${idle_timeout} seconds."
