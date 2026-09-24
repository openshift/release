#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly repo_root
readonly command_script="${repo_root}/ci-operator/step-registry/gcp-hcp/update-commit-status/gcp-hcp-update-commit-status-commands.sh"
test_root="$(mktemp -d)"
readonly test_root
trap 'rm -rf "${test_root}"' EXIT

readonly checkout_dir="${test_root}/checkout"
readonly mock_bin="${test_root}/bin"
readonly shared_dir="${test_root}/shared"
readonly token_path="${test_root}/oauth"
readonly curl_args_path="${test_root}/curl-args"

mkdir -p "${checkout_dir}" "${mock_bin}" "${shared_dir}"
git -C "${checkout_dir}" init --quiet
git -C "${checkout_dir}" config user.name "Test User"
git -C "${checkout_dir}" config user.email "test@example.com"
printf 'periodic checkout\n' >"${checkout_dir}/fixture"
git -C "${checkout_dir}" add fixture
git -C "${checkout_dir}" commit --quiet --message "test: periodic checkout"
checkout_sha="$(git -C "${checkout_dir}" rev-parse HEAD)"
readonly checkout_sha

cat >"${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${CURL_ARGS_PATH}"
EOF
chmod +x "${mock_bin}/curl"
printf 'test-token\n' >"${token_path}"

readonly job_spec='{"type":"periodic","job":"periodic-ci-openshift-online-gcp-hcp-infra-main-e2e-platform","buildid":"2102941394573201408","prowjobid":"13210ffa-5429-4440-a8dd-a24bd3fcb297","extra_refs":[{"org":"openshift-online","repo":"gcp-hcp-infra","base_ref":"main"}]}'
readonly prow_job_id="13210ffa-5429-4440-a8dd-a24bd3fcb297"

(
  cd "${checkout_dir}"
  PATH="${mock_bin}:${PATH}" \
    CURL_ARGS_PATH="${curl_args_path}" \
    GITHUB_TOKEN_PATH="${token_path}" \
    JOB_SPEC="${job_spec}" \
    PROW_JOB_ID="${prow_job_id}" \
    SHARED_DIR="${shared_dir}" \
    bash "${command_script}"
)

actual_sha="$(<"${shared_dir}/gcp-hcp-tested-sha")"
readonly actual_sha
if [[ "${actual_sha}" != "${checkout_sha}" ]]; then
  echo "FAIL: expected periodic checkout SHA ${checkout_sha}, got ${actual_sha}" >&2
  exit 1
fi

readonly expected_status_url="https://api.github.com/repos/openshift-online/gcp-hcp-infra/statuses/${checkout_sha}"
if ! grep -Fxq "${expected_status_url}" "${curl_args_path}"; then
  echo "FAIL: pending status was not posted to ${expected_status_url}" >&2
  exit 1
fi

echo "PASS: periodic-only target ref resolves the tested checkout SHA"

readonly ambiguous_shared_dir="${test_root}/ambiguous-shared"
readonly ambiguous_curl_args_path="${test_root}/ambiguous-curl-args"
readonly ambiguous_job_spec='{"type":"periodic","job":"periodic-ci-openshift-online-gcp-hcp-infra-main-e2e-platform","buildid":"2102941394573201408","prowjobid":"13210ffa-5429-4440-a8dd-a24bd3fcb297","extra_refs":[{"org":"openshift-online","repo":"gcp-hcp-infra","base_ref":"main"},{"org":"openshift","repo":"release","base_ref":"main"}]}'
mkdir -p "${ambiguous_shared_dir}"

if (
  cd "${checkout_dir}"
  PATH="${mock_bin}:${PATH}" \
    CURL_ARGS_PATH="${ambiguous_curl_args_path}" \
    GITHUB_TOKEN_PATH="${token_path}" \
    JOB_SPEC="${ambiguous_job_spec}" \
    PROW_JOB_ID="${prow_job_id}" \
    SHARED_DIR="${ambiguous_shared_dir}" \
    bash "${command_script}"
); then
  echo "FAIL: ambiguous periodic refs unexpectedly resolved the checkout SHA" >&2
  exit 1
fi

if [[ -e "${ambiguous_shared_dir}/gcp-hcp-tested-sha" ]]; then
  echo "FAIL: ambiguous periodic refs wrote a tested SHA" >&2
  exit 1
fi

if [[ -e "${ambiguous_curl_args_path}" ]]; then
  echo "FAIL: ambiguous periodic refs posted a GitHub status" >&2
  exit 1
fi

echo "PASS: ambiguous periodic refs do not use the checkout SHA"
