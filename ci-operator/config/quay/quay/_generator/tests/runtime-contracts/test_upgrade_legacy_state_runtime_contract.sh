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
cat >"${tmp}/bin/npm" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "${1:-}" == install ]] || exit 64
[[ -f package.json ]] || exit 65
printf '%s\n' "$*" >>"${NPM_INSTALL_LOG:?}"
[[ "${MOCK_NPM_PROVISION:-yes}" == yes ]] || exit 0
mkdir -p node_modules/.bin
ln -sf "${MOCK_CYPRESS_BIN:?}" node_modules/.bin/cypress
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
if [[ -n "${MOCK_SECRET_FILE:-}" ]]; then
  umask 077
  printf '%s' "${CYPRESS_UPGRADE_PASSWORD}" >"${MOCK_SECRET_FILE}"
fi
if [[ -n "${CYPRESS_AUTH_MARKER:-}" ]]; then
  printf '"Authorization": "Bearer %s\n' "${CYPRESS_AUTH_MARKER}" >&2
fi
if [[ "${ASSERT_CLEANUP:-no}" == yes && "${args}" == *upgrade_legacy_state_verify.cy.js* ]]; then
  spec=cypress/e2e/upgrade_legacy_state_verify.cy.js
  [[ "$(grep -c 'it("' "${spec}")" -eq 1 ]] || exit 91
  permission_line="$(grep -n '/permissions/team/' "${spec}" | head -1 | cut -d: -f1)"
  delete_line="$(grep -n 'DELETE' "${spec}" | head -1 | cut -d: -f1)"
  [[ "${permission_line}" -lt "${delete_line}" ]] || exit 92
fi
case "${JUNIT_KIND:-good}" in
  good) printf '<testsuite tests="1"><testcase name="state"><system-out>Authorization&quot;: &quot;Bearer %s</system-out></testcase></testsuite>\n' "${CYPRESS_AUTH_MARKER:-}" >"${out}" ;;
  zero) printf '<testsuite tests="0"></testsuite>\n' >"${out}" ;;
  failure) printf '<testsuite failures="1"><testcase><failure/></testcase></testsuite>\n' >"${out}" ;;
  skipped) printf '<testsuite skipped="1"><testcase><skipped/></testcase></testsuite>\n' >"${out}" ;;
  malformed) printf '<testsuite><testcase>' >"${out}" ;;
  secret) printf '<testsuite failures="1"><testcase><failure message="password=%s"><system-out>Authorization&quot;: &quot;Bearer %s</system-out></failure></testcase></testsuite>\n' "${CYPRESS_UPGRADE_PASSWORD}" "${CYPRESS_AUTH_MARKER:-}" >"${out}" ;;
esac
[[ "${CYPRESS_RC:-0}" == 0 ]] || exit "${CYPRESS_RC}"
EOF
cat >"${tmp}/bin/sed" <<'EOF'
#!/bin/bash
if [[ "${MOCK_SED_FAIL:-no}" == yes ]]; then
  exit 70
fi
exec /bin/sed "$@"
EOF
cat >"${tmp}/bin/mv" <<'EOF'
#!/bin/bash
if [[ "${MOCK_MV_FAIL:-no}" == yes ]]; then
  exit 71
fi
exec /bin/mv "$@"
EOF
chmod +x "${tmp}/bin/"*

run_seed() {
  local strict="$1" kind="$2" rc="$3" challenge="${4:-yes}" token="${5:-yes}" provision="${6:-yes}"
  local case_dir="${tmp}/seed-${strict}-${kind}-${rc}-${challenge}-${token}-${provision}"
  LAST_CASE_DIR="${case_dir}"
  mkdir -p "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/quay-api-tests/cypress/e2e"
  printf '{"name":"quay-api-tests"}\n' >"${case_dir}/quay-api-tests/package.json"
  printf '%s\n' https://quay.test >"${case_dir}/shared/quayroute"
  (cd "${case_dir}" && PATH="${tmp}/bin:${PATH}" SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" BUILD_ID=12345 \
    QUAY_UPGRADE_LEGACY_CYPRESS_STRICT="${strict}" JUNIT_KIND="${kind}" CYPRESS_RC="${rc}" MOCK_CHALLENGE="${challenge}" MOCK_TOKEN="${token}" MOCK_NPM_PROVISION="${provision}" \
    MOCK_CYPRESS_BIN="${tmp}/bin/node" NPM_INSTALL_LOG="${case_dir}/npm-install.log" \
    bash "${SEED}")
}

run_verify() {
  local strict="$1" kind="$2" rc="$3"
  local case_dir="${tmp}/verify-${strict}-${kind}-${rc}"
  mkdir -p "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/quay-api-tests/cypress/e2e"
  printf '{"name":"quay-api-tests"}\n' >"${case_dir}/quay-api-tests/package.json"
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
    MOCK_CYPRESS_BIN="${tmp}/bin/node" NPM_INSTALL_LOG="${case_dir}/npm-install.log" \
    bash "${VERIFY}")
}

assert_secret_safe_failure() {
  local phase="$1" case_dir script state_secret auth_marker actual_secret rc
  case_dir="${tmp}/secret-${phase}"
  set +o pipefail
  state_secret="$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 32)"
  auth_marker="$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 32)"
  set -o pipefail
  mkdir -p "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/quay-api-tests/cypress/e2e"
  printf '{"name":"quay-api-tests"}\n' >"${case_dir}/quay-api-tests/package.json"
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
    QUAY_UPGRADE_LEGACY_CYPRESS_STRICT=true JUNIT_KIND=secret CYPRESS_RC=7 CYPRESS_EMIT_SECRET=yes CYPRESS_BINARY_ARTIFACTS=yes CYPRESS_AUTH_MARKER="${auth_marker}" MOCK_SECRET_FILE="${case_dir}/actual-seed-password" \
    MOCK_CYPRESS_BIN="${tmp}/bin/node" NPM_INSTALL_LOG="${case_dir}/npm-install.log" \
    bash "${script}") >"${case_dir}/output.log" 2>&1
  rc=$?
  set -e
  actual_secret="${state_secret}"
  if [[ "${phase}" == seed ]]; then actual_secret="$(<"${case_dir}/actual-seed-password")"; fi
  [[ "${actual_secret}" =~ ^[A-Za-z0-9]{32}$ ]] || { echo "${phase} did not exercise its generated password" >&2; exit 1; }
  [[ "${rc}" -ne 0 ]] || { echo "${phase} accepted secret-bearing Cypress failure" >&2; exit 1; }
  if grep -Eq 'Cypress secret marker: [A-Za-z0-9]{32}' "${case_dir}/output.log" "${case_dir}/artifacts"/*/cypress-output.log; then echo "${phase} leaked a Cypress password marker" >&2; return 1; fi
  if grep -Eq 'password=[A-Za-z0-9]{32}' "${case_dir}/artifacts"/*/junit_*.xml; then echo "${phase} leaked a password in JUnit" >&2; return 1; fi
  if grep -Fq "${actual_secret}" "${case_dir}/output.log" "${case_dir}/artifacts"/*/cypress-output.log "${case_dir}/artifacts"/*/junit_*.xml; then echo "${phase} leaked its actual password" >&2; return 1; fi
  if grep -Fq "${auth_marker}" "${case_dir}/output.log" "${case_dir}/artifacts"/*/cypress-output.log "${case_dir}/artifacts"/*/junit_*.xml; then echo "${phase} leaked an Authorization marker" >&2; return 1; fi
  if ! grep -Fq '[redacted:password]' "${case_dir}/output.log" "${case_dir}/artifacts"/*/cypress-output.log "${case_dir}/artifacts"/*/junit_*.xml; then echo "${phase} did not redact passwords everywhere" >&2; return 1; fi
  if ! grep -Fq '[redacted:authorization]' "${case_dir}/output.log" "${case_dir}/artifacts"/*/cypress-output.log "${case_dir}/artifacts"/*/junit_*.xml; then echo "${phase} did not redact Authorization everywhere" >&2; return 1; fi
  # The generated password is redacted in a JUnit attribute and the
  # Authorization marker in text; both remain parseable XML after scrubbing.
  python3 - "${case_dir}/artifacts"/*/junit_*.xml <<'PY'
import sys
import xml.etree.ElementTree as ET
for report in sys.argv[1:]:
    ET.parse(report)
PY
  rm -f "${case_dir}/actual-seed-password"
  [[ ! -e "${case_dir}/shared/quay-upgrade-legacy-state.env" ]]
  [[ ! -e "${case_dir}/quay-api-tests/cypress/e2e/upgrade_legacy_state.cy.js" ]]
  [[ ! -e "${case_dir}/quay-api-tests/cypress/e2e/upgrade_legacy_state_verify.cy.js" ]]
  if find "${case_dir}/artifacts" -type d \( -name videos -o -name screenshots \) -print -quit | grep -q .; then
    echo "${phase} retained a Cypress video or screenshot" >&2
    return 1
  fi
}

assert_redaction_bypass_mutation_fails() {
  local original="${SEED}" mutated="${tmp}/seed-without-redaction.sh"
  cp "${original}" "${mutated}"
  # This mutation is deliberately narrow: the real adapter still runs, but
  # both console and JUnit copies bypass its sanitizer. The assertion helper
  # must reject that observable leak, proving the test is not a grep-only
  # success path.
  sed -i 's/scrub_cypress_text </cat </g' "${mutated}"
  SEED="${mutated}"
  if assert_secret_safe_failure seed; then
    echo 'redaction-bypass mutation was accepted' >&2
    exit 1
  fi
  SEED="${original}"
}

assert_preexisting_state_survives() {
  local case_dir="${tmp}/preexisting-state" state="${tmp}/expected-state"
  mkdir -p "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/quay-api-tests/cypress/e2e"
  printf 'sentinel-state-bytes\n' >"${state}"
  cp "${state}" "${case_dir}/shared/quay-upgrade-legacy-state.env"
  printf '%s\n' https://quay.test >"${case_dir}/shared/quayroute"
  set +e
  (cd "${case_dir}" && SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" bash "${SEED}") >/dev/null 2>&1
  local rc=$?
  set -e
  [[ "${rc}" -ne 0 ]]
  cmp "${state}" "${case_dir}/shared/quay-upgrade-legacy-state.env"
  set +e
  (cd "${case_dir}" && SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" bash "${SEED}") >/dev/null 2>&1
  rc=$?
  set -e
  [[ "${rc}" -ne 0 ]]
  cmp "${state}" "${case_dir}/shared/quay-upgrade-legacy-state.env"
}

assert_owned_failed_state_is_cleaned() {
  local case_dir="${tmp}/owned-failure"
  mkdir -p "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/quay-api-tests/cypress/e2e"
  printf '{"name":"quay-api-tests"}\n' >"${case_dir}/quay-api-tests/package.json"
  printf '%s\n' https://quay.test >"${case_dir}/shared/quayroute"
  set +e
  (cd "${case_dir}" && PATH="${tmp}/bin:${PATH}" SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" BUILD_ID=12348 \
    QUAY_UPGRADE_LEGACY_CYPRESS_STRICT=true JUNIT_KIND=good MOCK_NPM_PROVISION=no MOCK_CYPRESS_BIN="${tmp}/bin/node" NPM_INSTALL_LOG="${case_dir}/npm-install.log" \
    bash "${SEED}") >/dev/null 2>&1
  local rc=$?
  set -e
  [[ "${rc}" -ne 0 ]]
  [[ ! -e "${case_dir}/shared/quay-upgrade-legacy-state.env" ]]
}

assert_existing_state_survives_verify_guard() {
  local case_dir="${tmp}/verify-guard-state" state="${tmp}/verify-guard-expected"
  mkdir -p "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/quay-api-tests/cypress/e2e"
  cat >"${state}" <<'EOF'
OWNER='owner'
OWNER_PASSWORD='state-password'
MEMBER='member'
MEMBER_PASSWORD='member-password'
ORG='organization'
REPOSITORY='repository'
TEAM='team'
ROBOT='robot'
EOF
  cp "${state}" "${case_dir}/shared/quay-upgrade-legacy-state.env"
  printf '%s\n' https://quay.test >"${case_dir}/shared/quayroute"
  set +e
  (cd "${case_dir}" && PATH="${tmp}/bin:${PATH}" SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" \
    QUAY_UPGRADE_LEGACY_STATE_PHASE=verify MOCK_TOKEN=no bash "${SEED}") >/dev/null 2>&1
  local rc=$?
  set -e
  [[ "${rc}" -ne 0 ]]
  cmp "${state}" "${case_dir}/shared/quay-upgrade-legacy-state.env"
}

assert_sanitize_failure_is_fail_closed() {
  local phase="$1" mode="$2" case_dir script="${SEED}" secret
  case_dir="${tmp}/sanitize-failure-${phase}-${mode}"
  set +o pipefail
  secret="$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 32)"
  set -o pipefail
  mkdir -p "${case_dir}/shared" "${case_dir}/artifacts" "${case_dir}/quay-api-tests/cypress/e2e"
  printf '{"name":"quay-api-tests"}\n' >"${case_dir}/quay-api-tests/package.json"
  printf '%s\n' https://quay.test >"${case_dir}/shared/quayroute"
  if [[ "${phase}" == verify ]]; then
    script="${VERIFY}"
    cat >"${case_dir}/shared/quay-upgrade-legacy-state.env" <<EOF
OWNER='owner'
OWNER_PASSWORD='${secret}'
MEMBER='member'
MEMBER_PASSWORD='${secret}'
ORG='organization'
REPOSITORY='repository'
TEAM='team'
ROBOT='robot'
EOF
  fi
  set +e
  (cd "${case_dir}" && PATH="${tmp}/bin:${PATH}" SHARED_DIR="${case_dir}/shared" ARTIFACT_DIR="${case_dir}/artifacts" BUILD_ID=12349 \
    QUAY_UPGRADE_LEGACY_CYPRESS_STRICT=true JUNIT_KIND=secret CYPRESS_RC=7 CYPRESS_EMIT_SECRET=yes CYPRESS_AUTH_MARKER="${secret}" \
    MOCK_SED_FAIL="$([[ "${mode}" == sed ]] && echo yes || echo no)" MOCK_MV_FAIL="$([[ "${mode}" == mv ]] && echo yes || echo no)" \
    MOCK_CYPRESS_BIN="${tmp}/bin/node" NPM_INSTALL_LOG="${case_dir}/npm-install.log" MOCK_SECRET_FILE="${case_dir}/generated-password" \
    bash "${script}") >/dev/null 2>&1
  local rc=$?
  set -e
  [[ "${rc}" -ne 0 ]]
  if find "${case_dir}/artifacts" -type f \( -name 'junit_*.xml' -o -name 'cypress-output*' \) -print -quit | grep -q .; then
    echo "${phase} retained a raw Cypress artifact after sanitizer failure" >&2
    return 1
  fi
  ! grep -R -F -- "${secret}" "${case_dir}/artifacts"
}

# Positive seed executes the real RNG path, Bearer challenge/token exchange,
# and strict JUnit gate. The script must exit 0 with tracing disabled.
run_seed true good 0
grep -Fx 'install --no-audit --no-fund' "${LAST_CASE_DIR}/npm-install.log"
[[ -x "${LAST_CASE_DIR}/quay-api-tests/node_modules/.bin/cypress" ]]
if run_seed true good 0 yes yes no; then echo 'seed accepted a missing Cypress binary' >&2; exit 1; fi
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
mkdir -p "${stale_dir}/shared" "${stale_dir}/artifacts/quay-operator-upgrade-legacy-state" "${stale_dir}/quay-api-tests/cypress/e2e"
printf '{"name":"quay-api-tests"}\n' >"${stale_dir}/quay-api-tests/package.json"
printf '%s\n' https://quay.test >"${stale_dir}/shared/quayroute"
printf '<testsuite failures="1"><testcase><failure/></testcase></testsuite>\n' >"${stale_dir}/artifacts/quay-operator-upgrade-legacy-state/junit_upgrade_legacy_state-stale.xml"
(cd "${stale_dir}" && PATH="${tmp}/bin:${PATH}" SHARED_DIR="${stale_dir}/shared" ARTIFACT_DIR="${stale_dir}/artifacts" BUILD_ID=12346 QUAY_UPGRADE_LEGACY_CYPRESS_STRICT=true JUNIT_KIND=good MOCK_CYPRESS_BIN="${tmp}/bin/node" NPM_INSTALL_LOG="${stale_dir}/npm-install.log" bash "${SEED}")
for kind in zero failure skipped malformed; do
  if run_verify true "${kind}" 0; then echo "strict verify accepted ${kind} JUnit" >&2; exit 1; fi
done
assert_secret_safe_failure seed
assert_secret_safe_failure verify
assert_redaction_bypass_mutation_fails
assert_preexisting_state_survives
assert_owned_failed_state_is_cleaned
assert_existing_state_survives_verify_guard
assert_sanitize_failure_is_fail_closed seed sed
assert_sanitize_failure_is_fail_closed verify sed
assert_sanitize_failure_is_fail_closed seed mv
assert_sanitize_failure_is_fail_closed verify mv
echo 'legacy state adapter runtime mocks: PASS'
