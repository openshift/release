#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${CAPA_STEP_SCRIPT:-${REPO_ROOT}/ci-operator/step-registry/rosa/e2e/capa/rosa-e2e-capa-commands.sh}"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
MOCK_BIN="${TEST_ROOT}/bin"
mkdir -p "${MOCK_BIN}"

cat > "${MOCK_BIN}/cat" <<'EOF'
#!/bin/bash
case "$1" in
  /var/run/rosa-hcp-e2e-secrets/*|/var/run/rosa-e2e-aws-creds/*) printf 'fixture-only\n' ;;
  *) exec /bin/cat "$@" ;;
esac
EOF
cat > "${MOCK_BIN}/grep" <<'EOF'
#!/bin/bash
case "${*: -1}" in
  /var/run/rosa-e2e-aws-creds/*) printf '%s=fixture-only\n' "$1" ;;
  *) exec /bin/grep "$@" ;;
esac
EOF
cat > "${MOCK_BIN}/mktemp" <<'EOF'
#!/bin/bash
mkdir -p "${CASE_ROOT}/work"
printf '%s\n' "${CASE_ROOT}/work"
EOF
cat > "${MOCK_BIN}/git" <<'EOF'
#!/bin/bash
destination="${*: -1}"
mkdir -p "${destination}"
touch "${destination}/requirements.txt" "${destination}/requirements.yml"
EOF
cat > "${MOCK_BIN}/python3" <<'EOF'
#!/bin/bash
if [[ "$1" == '-m' ]]; then exit 0; fi
[[ "$1" == 'run-test-suite.py' ]] || exit 99
/bin/cp -a "${CASE_ROOT}/reports" test-results
printf 'fixture runner output\n'
exit "${RUNNER_STATUS}"
EOF
cat > "${MOCK_BIN}/cp" <<'EOF'
#!/bin/bash
if [[ "${COPY_FAILURE}" == true ]]; then exit 73; fi
exec /bin/cp "$@"
EOF
for command in ansible-galaxy jq helm; do
  printf '#!/bin/bash\nexit 0\n' > "${MOCK_BIN}/${command}"
done
chmod +x "${MOCK_BIN}"/*

report_name='test-run-tag-full-20261014_122440'
date_name='2026-10-14'
passed=0
for scenario in success failure partial missing copy-failure copy-failure-success symlinks results-symlink destination-symlink destination-date-symlink destination-file-symlink tee-failure; do
  export CASE_ROOT="${TEST_ROOT}/${scenario}" RUNNER_STATUS=0 COPY_FAILURE=false
  export ARTIFACT_DIR="${CASE_ROOT}/artifacts" SHARED_DIR="${CASE_ROOT}/shared"
  export ROSA_HCP_E2E_REPO=fixture-repo ROSA_HCP_E2E_BRANCH=main
  export OPENSHIFT_VERSION=4.22 CHANNEL_GROUP=stable DEPLOYMENT_MODE=fixture TEST_SUITE='--tag full'
  mkdir -p "${CASE_ROOT}/reports/${date_name}" "${ARTIFACT_DIR}"
  for extension in json html xml; do
    printf 'fixture report %s\n' "${extension}" > "${CASE_ROOT}/reports/${date_name}/${report_name}.${extension}"
  done
  printf 'not a report\n' > "${CASE_ROOT}/reports/${date_name}/credentials.json"
  printf 'not a report\n' > "${CASE_ROOT}/reports/kubeconfig"
  printf 'not a report\n' > "${CASE_ROOT}/reports/user_vars.yml"
  printf 'not a report\n' > "${CASE_ROOT}/reports/latest-tag-full.json"
  printf 'not a report\n' > "${CASE_ROOT}/reports/${date_name}/feature-verification-tag-full-20261014_122440.json"
  mkdir -p "${CASE_ROOT}/reports/${date_name}/nested"
  printf 'not a report\n' > "${CASE_ROOT}/reports/${date_name}/nested/${report_name}.json"
  expected_count=3
  expected_status=0
  case "${scenario}" in
    failure) RUNNER_STATUS=42; expected_status=42 ;;
    partial) rm "${CASE_ROOT}/reports/${date_name}/${report_name}.html"; expected_count=2 ;;
    missing) rm -rf "${CASE_ROOT}/reports"; mkdir "${CASE_ROOT}/reports"; expected_count=0 ;;
    copy-failure) COPY_FAILURE=true; RUNNER_STATUS=42; expected_status=42; expected_count=0 ;;
    copy-failure-success) COPY_FAILURE=true; expected_count=0 ;;
    symlinks)
      printf 'excluded fixture\n' > "${CASE_ROOT}/outside"
      ln -s "${CASE_ROOT}/outside" "${CASE_ROOT}/reports/${date_name}/test-run-20261014_122441.xml"
      ln -s "${CASE_ROOT}/reports/${date_name}" "${CASE_ROOT}/reports/2026-10-15"
      ;;
    results-symlink)
      mv "${CASE_ROOT}/reports" "${CASE_ROOT}/outside"
      ln -s "${CASE_ROOT}/outside" "${CASE_ROOT}/reports"
      expected_count=0
      ;;
    destination-symlink)
      mkdir "${CASE_ROOT}/outside"
      ln -s "${CASE_ROOT}/outside" "${ARTIFACT_DIR}/harness-results"
      expected_count=0
      ;;
    destination-date-symlink)
      mkdir -p "${CASE_ROOT}/outside" "${ARTIFACT_DIR}/harness-results"
      ln -s "${CASE_ROOT}/outside" "${ARTIFACT_DIR}/harness-results/${date_name}"
      expected_count=0
      ;;
    destination-file-symlink)
      printf 'untouched fixture\n' > "${CASE_ROOT}/outside"
      mkdir -p "${ARTIFACT_DIR}/harness-results/${date_name}"
      ln -s "${CASE_ROOT}/outside" "${ARTIFACT_DIR}/harness-results/${date_name}/${report_name}.html"
      expected_count=2
      ;;
    tee-failure)
      mkdir "${ARTIFACT_DIR}/rosa-hcp-e2e-test.log"
      expected_status=1
      ;;
  esac
  find "${ARTIFACT_DIR}" -type l -print | sort > "${CASE_ROOT}/links-before"
  actual_status=0
  PATH="${MOCK_BIN}:${PATH}" bash "${SCRIPT}" > "${CASE_ROOT}/output" 2>&1 || actual_status=$?
  find "${ARTIFACT_DIR}" -type l -print | sort > "${CASE_ROOT}/links-after"
  cmp "${CASE_ROOT}/links-before" "${CASE_ROOT}/links-after"
  [[ "${actual_status}" == "${expected_status}" ]] || { echo "FAIL ${scenario}: status ${actual_status}, expected ${expected_status}"; exit 1; }
  actual_count=$(find "${ARTIFACT_DIR}/harness-results" -type f 2>/dev/null | wc -l) || actual_count=0
  [[ "${actual_count}" -eq "${expected_count}" ]] || { echo "FAIL ${scenario}: reports ${actual_count}, expected ${expected_count}"; exit 1; }
  if [[ "${expected_count}" -gt 0 ]]; then
    for extension in json html xml; do
      [[ -f "${CASE_ROOT}/reports/${date_name}/${report_name}.${extension}" ]] || continue
      [[ "${scenario}" != destination-file-symlink || "${extension}" != html ]] || continue
      cmp "${CASE_ROOT}/reports/${date_name}/${report_name}.${extension}" "${ARTIFACT_DIR}/harness-results/${date_name}/${report_name}.${extension}"
    done
  fi
  for excluded in kubeconfig user_vars.yml latest-tag-full.json "${date_name}/credentials.json" "${date_name}/feature-verification-tag-full-20261014_122440.json" "${date_name}/nested"; do
    [[ ! -e "${ARTIFACT_DIR}/harness-results/${excluded}" ]]
  done
  [[ "${scenario}" == tee-failure ]] || /bin/grep -q 'fixture runner output' "${ARTIFACT_DIR}/rosa-hcp-e2e-test.log"
  if [[ "${scenario}" == copy-failure* ]]; then /bin/grep -q 'WARNING: could not persist a harness report' "${CASE_ROOT}/output"; fi
  if [[ "${scenario}" == destination-symlink || "${scenario}" == destination-date-symlink ]]; then [[ -z "$(find "${CASE_ROOT}/outside" -type f -print)" ]]; fi
  if [[ "${scenario}" == destination-file-symlink ]]; then [[ "$(/bin/cat "${CASE_ROOT}/outside")" == 'untouched fixture' ]]; fi
  echo "PASS ${scenario}"
  passed=$((passed + 1))
done
echo "${passed} consumer scenarios passed"
