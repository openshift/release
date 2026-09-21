#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly update_script="${repo_root}/ci-operator/step-registry/gcp-hcp/update-commit-status/gcp-hcp-update-commit-status-commands.sh"
readonly finalize_script="${repo_root}/ci-operator/step-registry/gcp-hcp/finalize-commit-status/gcp-hcp-finalize-commit-status-commands.sh"
readonly tested_sha="2a3bf7e96749af9d44db8c9267cc24fb3e629364"
readonly prow_job_id="29859b5d-0bc0-41dc-b678-6d1cfbcb64c2"
readonly job_spec="{\"refs\":{\"org\":\"openshift-online\",\"repo\":\"gcp-hcp-infra\",\"base_sha\":\"${tested_sha}\"}}"

test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT

mkdir -p "${test_root}/bin"
cat >"${test_root}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

while (( $# > 0 )); do
  if [[ "$1" == "--data" ]]; then
    printf '%s' "$2" >"${CAPTURE_PATH}"
    exit 0
  fi
  shift
done

echo "ERROR: unexpected GitHub GET request" >&2
exit 1
EOF
chmod +x "${test_root}/bin/curl"

run_status_step() {
  local command_script="$1"
  local shared_dir="$2"
  local capture_path="$3"
  local token_path="${shared_dir}/oauth"

  mkdir -p "${shared_dir}"
  printf 'test-token' >"${token_path}"

  CAPTURE_PATH="${capture_path}" \
  GITHUB_TOKEN_PATH="${token_path}" \
  JOB_SPEC="${job_spec}" \
  PATH="${test_root}/bin:${PATH}" \
  PROW_JOB_ID="${prow_job_id}" \
  SHARED_DIR="${shared_dir}" \
    bash "${command_script}" >/dev/null
}

assert_payload() {
  local capture_path="$1"
  local expected_state="$2"
  local expected_description="$3"

  jq -e \
    --arg state "${expected_state}" \
    --arg description "${expected_description}" \
    --arg target_url "https://prow.ci.openshift.org/prowjob?prowjob=${prow_job_id}" \
    '.state == $state
      and .context == "e2e/platform"
      and .description == $description
      and .target_url == $target_url' \
    "${capture_path}" >/dev/null
}

test_pending_on_first_invocation() {
  local shared_dir="${test_root}/pending-shared"
  local capture_path="${test_root}/pending-payload.json"

  run_status_step "${update_script}" "${shared_dir}" "${capture_path}"

  assert_payload "${capture_path}" pending "GCP HCP platform E2E test is running"
}

test_failure_without_test_success_marker() {
  local shared_dir="${test_root}/failure-shared"
  local capture_path="${test_root}/failure-payload.json"

  run_status_step "${update_script}" "${shared_dir}" "${capture_path}"
  run_status_step "${finalize_script}" "${shared_dir}" "${capture_path}"

  assert_payload "${capture_path}" failure "GCP HCP platform E2E test failed"
}

test_success_with_test_success_marker() {
  local shared_dir="${test_root}/success-shared"
  local capture_path="${test_root}/success-payload.json"

  run_status_step "${update_script}" "${shared_dir}" "${capture_path}"
  touch "${shared_dir}/gcp-hcp-e2e-tests-passed"
  run_status_step "${finalize_script}" "${shared_dir}" "${capture_path}"

  assert_payload "${capture_path}" success "GCP HCP platform E2E test passed"
}

test_records_tested_sha() {
  local shared_dir="${test_root}/tested-sha-shared"
  local capture_path="${test_root}/tested-sha-payload.json"

  run_status_step "${update_script}" "${shared_dir}" "${capture_path}"

  [[ "$(<"${shared_dir}/gcp-hcp-tested-sha")" == "${tested_sha}" ]]
}

test_pending_on_first_invocation
test_failure_without_test_success_marker
test_success_with_test_success_marker
test_records_tested_sha

echo "All gcp-hcp commit status tests passed"
