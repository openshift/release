#!/bin/bash
# Runtime contract tests for the legacy-state adapter.  They run the real
# scripts with mock HTTP, registry, skopeo, and Cypress binaries; no cluster or
# network credential is used.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../../../step-registry/quay/operator-upgrade-legacy-state" && pwd)"
SEED="${ROOT}/quay-operator-upgrade-legacy-state-commands.sh"
VERIFY="${ROOT}/../operator-upgrade-legacy-state-verify/quay-operator-upgrade-legacy-state-verify-commands.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
mkdir -p "${tmp}/bin"

cat >"${tmp}/bin/curl" <<'EOF'
#!/bin/bash
set -euo pipefail
args="$*"
last="${!#}"
if [[ "${args}" == *"/csrf_token"* ]]; then echo '{"csrf_token":"csrf"}'; exit 0; fi
if [[ "${args}" == *"/api/v1/user/"* ]]; then echo 200; exit 0; fi
if [[ "${last}" == *"/v2/auth" ]]; then
  [[ "${MOCK_CHALLENGE:-yes}" == yes ]] || exit 22
  [[ "${MOCK_TOKEN:-yes}" == yes ]] && echo '{"token":"mock-token"}' || echo '{}'
  exit 0
fi
if [[ "${last}" == *"/tags/list" ]]; then echo '{"tags":["upgrade-legacy"]}'; exit 0; fi
exit 1
EOF
cat >"${tmp}/bin/skopeo" <<'EOF'
#!/bin/bash
exit 0
EOF
cat >"${tmp}/bin/node" <<'EOF'
#!/bin/bash
set -euo pipefail
args="$*"
[[ "${1:-}" == "-e" ]] && exit 0
out=""
for arg in "$@"; do [[ "${arg}" == mochaFile=* ]] && out="${arg#mochaFile=}"; done
out="${out//\[hash\]/mock}"
mkdir -p "$(dirname "${out}")"
if [[ "${CYPRESS_BINARY_ARTIFACTS:-no}" == yes ]]; then
  mkdir -p "${ARTIFACT_DIR}/videos" "${ARTIFACT_DIR}/screenshots"
  printf '%s' binary > "${ARTIFACT_DIR}/videos/failure.webm"
  printf '%s' binary > "${ARTIFACT_DIR}/screenshots/failure.png"
fi
if [[ "${CYPRESS_EMIT_SECRET:-no}" == yes ]]; then
  printf 'Cypress secret marker: %s\n' "${CYPRESS_UPGRADE_PASSWORD}" >&2
fi
if [[ "${ASSERT_CLEANUP:-no}" == yes && "${args}" == *upgrade_legacy_state_verify.cy.js* ]]; then
  spec=cypress/e2e/upgrade_legacy_state_verify.cy.js
  [[ "$(grep -c 'it("' "${spec}")" -eq 1 ]] || exit 91
  permission_line="$(grep -n '/permissions/team/' "${spec}" | head -1 | cut -d: -f1)"
  delete_line="$(grep -n 'DELETE' "${spec}" | head -1 | cut -d: -f1)"
  [[ "${permission_line}" -lt "${delete_line}" ]] || exit 92
fi
case "${JUNIT_KIND:-good}" in
  good) printf '<testsuite tests="1"><testcase name="state"/></testsuite>\n' >"${out}" ;;
  zero) printf '<testsuite tests="0"></testsuite>\n' >"${out}" ;;
  failure) printf '<testsuite failures="1"><testcase><failure/></testcase></testsuite>\n' >"${out}" ;;
  skipped) printf '<testsuite skipped="1"><testcase><skipped/></testcase></testsuite>\n' >"${out}" ;;
  malformed) printf '<testsuite><testcase>' >"${out}" ;;
  secret) printf '<testsuite failures="1"><testcase><failure message="password=%s"/></testcase></testsuite>\n' "${CYPRESS_UPGRADE_PASSWORD}" >"${out}" ;;
esac
[[ "${CYPRESS_RC:-0}" == 0 ]] || exit "${CYPRESS_RC}"
EOF
chmod +x "${tmp}/bin/"*

run_seed() {
  local strict="$1" kind="$2" rc="$3" challenge="${4:-yes}" token="${5:-yes}"
  local case_dir="${tmp}/seed-${strict}-${kind}-${rc}-${challenge}-${token}"
  mkdir -p "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/quay-api-tests/cypress/e2e" "${case_dir}/quay-api-tests/node_modules/.bin"
  ln -s "${tmp}/bin/node" "${case_dir}/quay-api-tests/node_modules/.bin/cypress"
  printf '%s\n' https://quay.test >"${case_dir}/shared/quayroute"
  (cd "${case_dir}" && PATH="${tmp}/bin:${PATH}" SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" BUILD_ID=12345 \
    QUAY_UPGRADE_LEGACY_CYPRESS_STRICT="${strict}" JUNIT_KIND="${kind}" CYPRESS_RC="${rc}" MOCK_CHALLENGE="${challenge}" MOCK_TOKEN="${token}" \
    bash "${SEED}")
}

run_verify() {
  local strict="$1" kind="$2" rc="$3"
  local case_dir="${tmp}/verify-${strict}-${kind}-${rc}"
  mkdir -p "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/quay-api-tests/cypress/e2e" "${case_dir}/quay-api-tests/node_modules/.bin"
  ln -s "${tmp}/bin/node" "${case_dir}/quay-api-tests/node_modules/.bin/cypress"
  printf '%s\n' https://quay.test >"${case_dir}/shared/quayroute"
  cat >"${case_dir}/shared/quay-upgrade-legacy-state.env" <<EOF
OWNER='owner'
OWNER_PASSWORD='password'
MEMBER='member'
MEMBER_PASSWORD='member-password'
ORG='organization'
REPOSITORY='repository'
TEAM='team'
ROBOT='robot'
EOF
  (cd "${case_dir}" && PATH="${tmp}/bin:${PATH}" SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" ASSERT_CLEANUP=yes \
    QUAY_UPGRADE_LEGACY_CYPRESS_STRICT="${strict}" JUNIT_KIND="${kind}" CYPRESS_RC="${rc}" \
    bash "${VERIFY}")
}

assert_secret_safe_failure() {
  local phase="$1" case_dir script state_secret rc
  case_dir="${tmp}/secret-${phase}"
  set +o pipefail
  state_secret="$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 32)"
  set -o pipefail
  mkdir -p "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/quay-api-tests/cypress/e2e" "${case_dir}/quay-api-tests/node_modules/.bin"
  ln -s "${tmp}/bin/node" "${case_dir}/quay-api-tests/node_modules/.bin/cypress"
  printf '%s\n' https://quay.test >"${case_dir}/shared/quayroute"
  script="${SEED}"
  if [[ "${phase}" == verify ]]; then
    script="${VERIFY}"
    cat >"${case_dir}/shared/quay-upgrade-legacy-state.env" <<EOF
OWNER='owner'
OWNER_PASSWORD='${state_secret}'
MEMBER='member'
MEMBER_PASSWORD='${state_secret}'
ORG='organization'
REPOSITORY='repository'
TEAM='team'
ROBOT='robot'
EOF
  fi
  set +e
  (cd "${case_dir}" && PATH="${tmp}/bin:${PATH}" SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" BUILD_ID=12347 \
    QUAY_UPGRADE_LEGACY_CYPRESS_STRICT=true JUNIT_KIND=secret CYPRESS_RC=7 CYPRESS_EMIT_SECRET=yes CYPRESS_BINARY_ARTIFACTS=yes \
    bash "${script}") >"${case_dir}/output.log" 2>&1
  rc=$?
  set -e
  [[ "${rc}" -ne 0 ]] || { echo "${phase} accepted secret-bearing Cypress failure" >&2; exit 1; }
  ! grep -Eq 'Cypress secret marker: [A-Za-z0-9]{32}' "${case_dir}/output.log"
  ! grep -Eq 'Cypress secret marker: [A-Za-z0-9]{32}' "${case_dir}/artifacts"/*/cypress-output.log
  ! grep -Eq 'password=[A-Za-z0-9]{32}' "${case_dir}/artifacts"/*/junit_*.xml
  ! grep -Fq "${state_secret}" "${case_dir}/output.log"
  ! grep -Fq "${state_secret}" "${case_dir}/artifacts"/*/cypress-output.log
  ! grep -Fq "${state_secret}" "${case_dir}/artifacts"/*/junit_*.xml
  grep -Fq '<redacted:password>' "${case_dir}/output.log"
  grep -Fq '<redacted:password>' "${case_dir}/artifacts"/*/cypress-output.log
  grep -Fq '<redacted:password>' "${case_dir}/artifacts"/*/junit_*.xml
  [[ ! -e "${case_dir}/shared/quay-upgrade-legacy-state.env" ]]
  [[ ! -e "${case_dir}/quay-api-tests/cypress/e2e/upgrade_legacy_state.cy.js" ]]
  [[ ! -e "${case_dir}/quay-api-tests/cypress/e2e/upgrade_legacy_state_verify.cy.js" ]]
  [[ ! -d "${case_dir}/artifacts"/*/videos ]]
  [[ ! -d "${case_dir}/artifacts"/*/screenshots ]]
}

# Positive seed executes the real RNG path, Bearer challenge/token exchange,
# and strict JUnit gate. The script must exit 0 with tracing disabled.
run_seed true good 0
# Default false preserves existing old lanes: Cypress failure itself remains
# non-fatal only when the strict opt-in was not selected.
run_seed false zero 7
for kind in zero failure skipped malformed; do
  if run_seed true "${kind}" 0; then echo "strict seed accepted ${kind} JUnit" >&2; exit 1; fi
done
if run_seed true good 0 no; then echo 'seed accepted registry token HTTP failure' >&2; exit 1; fi
if run_seed true good 0 yes no; then echo 'seed accepted missing registry token' >&2; exit 1; fi
run_verify true good 0
# A stale failed file with the adapter naming pattern is removed before each
# Cypress run; a fresh successful report is the only report strict mode reads.
stale_dir="${tmp}/stale-junit"
mkdir -p "${stale_dir}/shared" "${stale_dir}/artifacts/quay-operator-upgrade-legacy-state" "${stale_dir}/quay-api-tests/cypress/e2e" "${stale_dir}/quay-api-tests/node_modules/.bin"
ln -s "${tmp}/bin/node" "${stale_dir}/quay-api-tests/node_modules/.bin/cypress"
printf '%s\n' https://quay.test >"${stale_dir}/shared/quayroute"
printf '<testsuite failures="1"><testcase><failure/></testcase></testsuite>\n' >"${stale_dir}/artifacts/quay-operator-upgrade-legacy-state/junit_upgrade_legacy_state-stale.xml"
(cd "${stale_dir}" && PATH="${tmp}/bin:${PATH}" SHARED_DIR="${stale_dir}/shared" ARTIFACT_DIR="${stale_dir}/artifacts" BUILD_ID=12346 QUAY_UPGRADE_LEGACY_CYPRESS_STRICT=true JUNIT_KIND=good bash "${SEED}")
for kind in zero failure skipped malformed; do
  if run_verify true "${kind}" 0; then echo "strict verify accepted ${kind} JUnit" >&2; exit 1; fi
done
assert_secret_safe_failure seed
assert_secret_safe_failure verify
echo 'legacy state adapter runtime mocks: PASS'
