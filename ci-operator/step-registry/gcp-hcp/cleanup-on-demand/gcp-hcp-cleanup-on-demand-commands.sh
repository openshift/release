#!/usr/bin/env bash
set -euo pipefail

# Always verify teardown in this persistent customer project. The CLI's
# nodepool delete only initiates deletion, and a successful Ginkgo exit does
# not prove that the worker VMs have disappeared.
if [[ -z "${SHARED_DIR:-}" || ! -d "${SHARED_DIR}" ]]; then
  echo "ERROR: fallback cleanup needs SHARED_DIR" >&2
  exit 1
fi
readonly verified_path="${SHARED_DIR}/gcp-hcp-cleanup-verified"
rm -f "${verified_path}"
if [[ ! -s "${SHARED_DIR}/hosted-cluster-name" && ! -s "${SHARED_DIR}/nodepool-name" ]]; then
  if [[ -e "${SHARED_DIR}/gcp-hcp-e2e-tests-started" ]]; then
    echo "ERROR: lifecycle started without recording resource names; cleanup cannot be verified" >&2
    exit 1
  fi
  echo "Lifecycle did not start; no test resources were created"
  touch "${verified_path}"
  exit 0
fi

for file in hosted-cluster-name nodepool-name customer-project-id region api-endpoint wif-cred.json; do
  if [[ ! -s "${SHARED_DIR}/${file}" ]]; then
    echo "ERROR: fallback cleanup needs ${file} in SHARED_DIR" >&2
    exit 1
  fi
done

cluster_name="$(<"${SHARED_DIR}/hosted-cluster-name")"
nodepool_name="$(<"${SHARED_DIR}/nodepool-name")"
customer_project="$(<"${SHARED_DIR}/customer-project-id")"
region="$(<"${SHARED_DIR}/region")"
api_endpoint="$(<"${SHARED_DIR}/api-endpoint")"
readonly cluster_name nodepool_name customer_project region api_endpoint
readonly cli="${GCPHCPCTL_PATH:-/usr/bin/gcphcpctl}"

# Only remove the randomly named resources created by this test in its
# configured customer project. Never target a regional or management project.
if [[ ! "${cluster_name}" =~ ^e2e-hc-[0-9a-f]{6}$ ]] ||
   [[ "${nodepool_name}" != "${cluster_name}-np" ]] ||
   [[ -z "${E2E_TARGET_CUSTOMER_PROJECT_ID:-}" ]] ||
   [[ "${customer_project}" != "${E2E_TARGET_CUSTOMER_PROJECT_ID}" ]] ||
   [[ -z "${E2E_TARGET_REGION:-}" ]] ||
   [[ "${region}" != "${E2E_TARGET_REGION}" ]] ||
   [[ -z "${E2E_TARGET_API_ENDPOINT:-}" ]] ||
   [[ "${api_endpoint}" != "${E2E_TARGET_API_ENDPOINT}" ]] ||
   [[ "${api_endpoint}" != https://* ]] ||
   [[ ! -x "${cli}" ]]; then
  echo "ERROR: fallback cleanup target or CLI is invalid" >&2
  exit 1
fi

infra_id=""
if [[ -s "${SHARED_DIR}/hosted-cluster-infra-id" ]]; then
  infra_id="$(<"${SHARED_DIR}/hosted-cluster-infra-id")"
  if [[ ! "${infra_id}" =~ ^e2e-hc-[0-9a-f]{4}$ ]]; then
    echo "ERROR: fallback cleanup infra ID is invalid" >&2
    exit 1
  fi
fi

export GOOGLE_APPLICATION_CREDENTIALS="${SHARED_DIR}/wif-cred.json"
export GCPHCPCTL_API_ENDPOINT="${api_endpoint}"
export GCPHCPCTL_PROJECT="${customer_project}"
export GCPHCPCTL_REGION="${region}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

is_not_found() {
  grep -Eiq '(^|: )not found[[:space:]]*$' "$1"
}

lookup_cluster() {
  if timeout 2m "${cli}" cluster get "${cluster_name}" -o json \
      >"${tmp_dir}/cluster.json" 2>"${tmp_dir}/cluster.err"; then
    return 0
  fi
  if is_not_found "${tmp_dir}/cluster.err"; then
    return 1
  fi
  echo "ERROR: cannot inspect test cluster ${cluster_name} through the Platform API" >&2
  return 2
}

lookup_nodepool() {
  if timeout 2m "${cli}" nodepool get "${nodepool_name}" -o json \
      >"${tmp_dir}/nodepool.json" 2>"${tmp_dir}/nodepool.err"; then
    return 0
  fi
  if is_not_found "${tmp_dir}/nodepool.err"; then
    return 1
  fi
  echo "ERROR: cannot inspect test nodepool ${nodepool_name} through the Platform API" >&2
  return 2
}

list_worker_instances() {
  if ! timeout 2m gcloud compute instances list --project="${customer_project}" \
      --format=json >"${tmp_dir}/instances.json" 2>"${tmp_dir}/instances.err"; then
    echo "ERROR: cannot list worker VMs in customer project ${customer_project}" >&2
    return 1
  fi
  if ! jq --arg cluster "${cluster_name}" '[.[] |
    (.labels["hypershift-openshift-io-cluster"] // "") as $labelCluster |
    (.labels["hypershift-openshift-io-infra-id"] // "") as $labelInfra |
    ([.metadata.items[]? | select(.key == "hypershift-cluster") | .value] | first // "") as $metadataCluster |
    ([.metadata.items[]? | select(.key == "hypershift-infra-id") | .value] | first // "") as $metadataInfra |
    select($labelCluster == $cluster or $metadataCluster == $cluster) |
    {name: .name, zone: (.zone | split("/")[-1]),
     infra: (if $labelInfra != "" then $labelInfra else $metadataInfra end),
     labelCluster: $labelCluster, metadataCluster: $metadataCluster,
     labelInfra: $labelInfra, metadataInfra: $metadataInfra}
  ]' "${tmp_dir}/instances.json" >"${tmp_dir}/workers.json"; then
    echo "ERROR: cannot parse worker VM inventory" >&2
    return 1
  fi
}

ensure_workers_absent() {
  local deadline count worker name zone vm_infra label_cluster metadata_cluster label_infra metadata_infra unsafe=0
  deadline=$((SECONDS + 120))
  while true; do
    list_worker_instances || return 1
    count="$(jq 'length' "${tmp_dir}/workers.json")"
    if (( count == 0 )); then
      echo "No worker VMs remain for ${cluster_name}"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      break
    fi
    echo "Waiting for ${count} worker VM(s) from ${cluster_name} to be deleted"
    sleep 20
  done

  # The nodepool controller normally deletes these VMs. If it did not,
  # remove only VMs with this run's exact cluster and infra identity.
  if [[ -z "${infra_id}" ]]; then
    echo "ERROR: cannot safely delete worker VMs without this run's infra ID" >&2
    return 1
  fi
  while IFS= read -r worker; do
    name="$(jq -r '.name' <<<"${worker}")"
    zone="$(jq -r '.zone' <<<"${worker}")"
    vm_infra="$(jq -r '.infra' <<<"${worker}")"
    label_cluster="$(jq -r '.labelCluster' <<<"${worker}")"
    metadata_cluster="$(jq -r '.metadataCluster' <<<"${worker}")"
    label_infra="$(jq -r '.labelInfra' <<<"${worker}")"
    metadata_infra="$(jq -r '.metadataInfra' <<<"${worker}")"
    if [[ ! "${name}" =~ ^[a-z][a-z0-9-]*[a-z0-9]$ ]] ||
       [[ ! "${zone}" =~ ^[a-z0-9-]+$ ]] ||
       [[ "${zone}" != "${region}-"* ]] ||
       [[ -n "${label_cluster}" && "${label_cluster}" != "${cluster_name}" ]] ||
       [[ -n "${metadata_cluster}" && "${metadata_cluster}" != "${cluster_name}" ]] ||
       [[ -n "${label_infra}" && "${label_infra}" != "${infra_id}" ]] ||
       [[ -n "${metadata_infra}" && "${metadata_infra}" != "${infra_id}" ]] ||
       [[ "${vm_infra}" != "${infra_id}" ]]; then
      echo "ERROR: refusing to delete a worker VM without matching test identity and region" >&2
      unsafe=1
      continue
    fi
    echo "Deleting leftover worker VM ${name} in ${zone} from ${customer_project}"
    if ! timeout 3m gcloud compute instances delete "${name}" \
        --project="${customer_project}" --zone="${zone}" --quiet \
        >"${tmp_dir}/worker-delete.out" 2>"${tmp_dir}/worker-delete.err"; then
      echo "WARNING: worker VM delete did not complete; checking again" >&2
    fi
  done < <(jq -c '.[]' "${tmp_dir}/workers.json")
  if (( unsafe != 0 )); then
    return 1
  fi

  deadline=$((SECONDS + 180))
  while true; do
    list_worker_instances || return 1
    count="$(jq 'length' "${tmp_dir}/workers.json")"
    if (( count == 0 )); then
      echo "All worker VMs from ${cluster_name} are absent"
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo "ERROR: ${count} worker VM(s) from ${cluster_name} remain" >&2
      return 1
    fi
    sleep 20
  done
}

cleanup_failed=0
cluster_present=false
if lookup_cluster; then
  cluster_present=true
  observed_infra_id="$(jq -r '.spec.infraID // empty' "${tmp_dir}/cluster.json" 2>/dev/null || true)"
  if [[ -n "${observed_infra_id}" ]]; then
    if [[ ! "${observed_infra_id}" =~ ^e2e-hc-[0-9a-f]{4}$ ]] ||
       [[ -n "${infra_id}" && "${infra_id}" != "${observed_infra_id}" ]]; then
      echo "ERROR: test cluster infra ID does not match its cleanup metadata" >&2
      exit 1
    fi
    infra_id="${observed_infra_id}"
  fi
else
  lookup_result=$?
  if (( lookup_result != 1 )); then
    cleanup_failed=1
    cluster_present=true
  fi
fi

echo "Verifying cleanup for ${cluster_name} in customer project ${customer_project}"
export CLOUDSDK_CONFIG="${tmp_dir}/gcloud"
gcloud_ready=true
if ! command -v gcloud >/dev/null ||
   ! timeout 1m gcloud auth login --cred-file="${SHARED_DIR}/wif-cred.json" --quiet \
      >"${tmp_dir}/gcloud-auth.out" 2>"${tmp_dir}/gcloud-auth.err"; then
  echo "ERROR: cannot authenticate gcloud to verify customer worker VMs" >&2
  gcloud_ready=false
  cleanup_failed=1
fi

# If the cluster vanished before the infra ID was persisted, its worker labels
# or metadata can still identify the exact network and IAM resources to destroy.
if [[ -z "${infra_id}" && "${gcloud_ready}" == true ]]; then
  if list_worker_instances; then
    recovered_infra="$(jq -r '[.[].infra] | unique | if length == 1 then .[0] else empty end' "${tmp_dir}/workers.json")"
    if [[ "${recovered_infra}" =~ ^e2e-hc-[0-9a-f]{4}$ ]]; then
      infra_id="${recovered_infra}"
      echo "Recovered test infra ID from worker identity"
    fi
  else
    cleanup_failed=1
  fi
fi

# A delete request is asynchronous; the nodepool must reach NotFound before
# the cluster is removed, so its finalizer can finish worker teardown.
if ! timeout 2m "${cli}" nodepool delete "${nodepool_name}" --confirm \
    >"${tmp_dir}/nodepool.out" 2>"${tmp_dir}/nodepool.err"; then
  if ! is_not_found "${tmp_dir}/nodepool.err"; then
    echo "ERROR: could not delete test nodepool ${nodepool_name}" >&2
    cleanup_failed=1
  fi
fi

deadline=$((SECONDS + 600))
while true; do
  if lookup_nodepool; then
    if (( SECONDS >= deadline )); then
      echo "ERROR: test nodepool ${nodepool_name} was not deleted within 10 minutes" >&2
      cleanup_failed=1
      break
    fi
    sleep 30
  else
    lookup_result=$?
    if (( lookup_result != 1 )); then
      cleanup_failed=1
    else
      echo "Test nodepool ${nodepool_name} is absent"
    fi
    break
  fi
done

if [[ "${gcloud_ready}" == true ]] && ! ensure_workers_absent; then
  cleanup_failed=1
fi

if [[ "${cluster_present}" == true ]]; then
  if ! timeout 2m "${cli}" cluster delete "${cluster_name}" --confirm \
      >"${tmp_dir}/delete.out" 2>"${tmp_dir}/delete.err"; then
    if ! is_not_found "${tmp_dir}/delete.err"; then
      echo "ERROR: could not start deletion of test cluster ${cluster_name}" >&2
      cleanup_failed=1
    fi
  fi
fi

deadline=$((SECONDS + 600))
while true; do
  if lookup_cluster; then
    if (( SECONDS >= deadline )); then
      echo "ERROR: test cluster ${cluster_name} was not deleted within 10 minutes" >&2
      cleanup_failed=1
      break
    fi
    sleep 30
  else
    lookup_result=$?
    if (( lookup_result != 1 )); then
      cleanup_failed=1
    else
      echo "Test cluster ${cluster_name} is absent"
    fi
    break
  fi
done

if [[ -z "${infra_id}" ]]; then
  echo "ERROR: test infra ID is unknown; customer network and IAM cleanup needs attention" >&2
  cleanup_failed=1
else
  # Both destroy commands tolerate resources already removed by Ginkgo.
  if ! timeout 8m "${cli}" network destroy "${infra_id}" --yes; then
    echo "ERROR: could not destroy test network infrastructure ${infra_id}" >&2
    cleanup_failed=1
  fi
  if ! timeout 8m "${cli}" iam destroy "${infra_id}" --yes; then
    echo "ERROR: could not destroy test IAM infrastructure ${infra_id}" >&2
    cleanup_failed=1
  fi
fi

if [[ "${gcloud_ready}" == true ]]; then
  if ! list_worker_instances; then
    cleanup_failed=1
  elif (( $(jq 'length' "${tmp_dir}/workers.json") != 0 )); then
    echo "ERROR: worker VMs remain after HostedCluster infrastructure cleanup" >&2
    cleanup_failed=1
  fi
fi

if (( cleanup_failed != 0 )); then
  exit 1
fi
touch "${verified_path}"
echo "HostedCluster, nodepool, worker VMs, network, and IAM cleanup verified"
