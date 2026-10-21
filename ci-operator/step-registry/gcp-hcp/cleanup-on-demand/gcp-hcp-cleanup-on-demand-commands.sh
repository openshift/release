#!/usr/bin/env bash
set -euo pipefail

# Ginkgo normally cleans up this persistent customer project itself. This post
# step covers a failed or timed-out test process that did not finish cleanup.
if [[ -z "${SHARED_DIR:-}" || ! -d "${SHARED_DIR}" ]]; then
  echo "ERROR: fallback cleanup needs SHARED_DIR" >&2
  exit 1
fi
if [[ -e "${SHARED_DIR}/gcp-hcp-e2e-tests-passed" ]]; then
  echo "HC lifecycle passed; no fallback cleanup needed"
  exit 0
fi
if [[ ! -s "${SHARED_DIR}/hosted-cluster-name" && ! -s "${SHARED_DIR}/nodepool-name" ]]; then
  echo "No test HostedCluster metadata; no fallback cleanup needed"
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
    exit 1
  fi
fi

echo "Fallback cleanup for ${cluster_name} in customer project ${customer_project}"
cleanup_failed=0
if ! timeout 2m "${cli}" nodepool delete "${nodepool_name}" --confirm \
    >"${tmp_dir}/nodepool.out" 2>"${tmp_dir}/nodepool.err"; then
  if ! is_not_found "${tmp_dir}/nodepool.err"; then
    echo "ERROR: could not delete test nodepool ${nodepool_name}" >&2
    cleanup_failed=1
  fi
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

deadline=$((SECONDS + 900))
while true; do
  if lookup_cluster; then
    if (( SECONDS >= deadline )); then
      echo "ERROR: test cluster ${cluster_name} was not deleted within 15 minutes" >&2
      exit 1
    fi
    sleep 30
  else
    lookup_result=$?
    if (( lookup_result != 1 )); then
      exit 1
    fi
    break
  fi
done
echo "Test cluster ${cluster_name} is absent"

if [[ -z "${infra_id}" ]]; then
  echo "ERROR: test infra ID is unknown; customer network and IAM cleanup needs attention" >&2
  exit 1
fi

# Both destroy commands tolerate resources already removed by Ginkgo cleanup.
if ! timeout 8m "${cli}" network destroy "${infra_id}" --yes; then
  echo "ERROR: could not destroy test network infrastructure ${infra_id}" >&2
  cleanup_failed=1
fi
if ! timeout 8m "${cli}" iam destroy "${infra_id}" --yes; then
  echo "ERROR: could not destroy test IAM infrastructure ${infra_id}" >&2
  cleanup_failed=1
fi

if (( cleanup_failed != 0 )); then
  exit 1
fi
echo "Fallback HostedCluster cleanup completed"
