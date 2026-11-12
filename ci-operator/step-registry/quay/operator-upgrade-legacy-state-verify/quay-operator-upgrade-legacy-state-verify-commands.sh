#!/bin/bash
set -euo pipefail

# This is the verification half of the legacy-state adapter. Its source half
# writes the mode-0600 SHARED_DIR contract; no credential is logged here.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-operator-upgrade-legacy-state-verify"
mkdir -p "${ARTIFACT_DIR}"
umask 077
STATE_FILE="${SHARED_DIR}/quay-upgrade-legacy-state.env"
ROUTE_FILE="${SHARED_DIR}/quayroute"
STRICT="${QUAY_UPGRADE_LEGACY_CYPRESS_STRICT:-false}"
RAW_CYPRESS_OUTPUT=""
RAW_CYPRESS_DIR=""
PUBLISH_CYPRESS_DIR=""
fail() { echo "ERROR: $*" >&2; exit 1; }
cleanup_sensitive_runtime() {
  rm -rf "${RAW_CYPRESS_DIR}" "${PUBLISH_CYPRESS_DIR}"
  rm -f "${RAW_CYPRESS_OUTPUT}" "${STATE_FILE}" quay-api-tests/cypress/e2e/upgrade_legacy_state_verify.cy.js
  rm -rf "${ARTIFACT_DIR}/videos" "${ARTIFACT_DIR}/screenshots"
}
trap cleanup_sensitive_runtime EXIT
strict_junit_success() {
  local pattern="$1" files=() file tests=0
  shopt -s nullglob
  files=( ${pattern} )
  shopt -u nullglob
  (( ${#files[@]} > 0 )) || return 1
  for file in "${files[@]}"; do
    [[ -s "${file}" ]] || return 1
    grep -q '<testsuite\|<testsuites' "${file}" || return 1
    grep -q '</testsuite>\|</testsuites>' "${file}" || return 1
    grep -Eq '<(failure|error|skipped)([[:space:]/>])|failures="[1-9][0-9]*"|errors="[1-9][0-9]*"|skipped="[1-9][0-9]*"' "${file}" && return 1
    tests=$((tests + $(grep -o '<testcase[[:space:]>]' "${file}" | wc -l)))
  done
  (( tests > 0 ))
}
scrub_cypress_text() {
  local -
  set +x
  sed -u -E \
    -e 's@(Authorization(&quot;|")?[[:blank:]]*:[[:blank:]]*(&quot;|")?([A-Za-z]+[[:blank:]]+)?)[A-Za-z0-9._~+/=-]{16,}@\1[redacted:authorization]@Ig' \
    -e 's|(Authorizatio[n]:[[:blank:]]*([A-Za-z]+[[:blank:]]+)?)[A-Za-z0-9._~+/=-]{16,}|\1[redacted:authorization]|Ig' \
    -e 's|(X-CSRF-Token:[[:blank:]]*)[A-Za-z0-9._~+/=-]+|\1[redacted:csrf]|Ig' \
    -e 's|(_csrf_token=)[A-Za-z0-9._~+/=-]+|\1[redacted:session]|g' \
    -e 's#("[A-Za-z0-9_-]*(password|secret|token)(_?(key|code))?"[[:blank:]]*:[[:blank:]]*")([^"\\]|\\.)+#\1[redacted:value]#Ig' \
    | sed -u -e "s|${OWNER_PASSWORD}|[redacted:password]|g" -e "s|${MEMBER_PASSWORD}|[redacted:password]|g"
}
prepare_cypress_dependencies() {
  # Match the supported dependency setup in quay-test-api-legacy. The adapter
  # runs earlier in the generated workflow, so it cannot rely on that later
  # ref to provision node_modules/.bin/cypress.
  (
    cd quay-api-tests
    [[ -f package.json ]] || fail "quay-api-tests package.json is missing"
    npm install --no-audit --no-fund
    [[ -x node_modules/.bin/cypress ]] || fail "Cypress binary was not installed in quay-api-tests"
  )
}
publish_sanitized_cypress_artifacts() {
  local file base
  PUBLISH_CYPRESS_DIR="$(mktemp -d "${ARTIFACT_DIR}/.quay-sanitized.XXXXXX")" || return 1
  scrub_cypress_text < "${RAW_CYPRESS_OUTPUT}" > "${PUBLISH_CYPRESS_DIR}/cypress-output.log" || return 1
  shopt -s nullglob
  for file in "${RAW_CYPRESS_DIR}"/junit_upgrade_legacy_state_verify-*.xml; do
    base="$(basename "${file}")"
    scrub_cypress_text < "${file}" > "${PUBLISH_CYPRESS_DIR}/${base}" || return 1
  done
  shopt -u nullglob
  # The only files moved into ARTIFACT_DIR are complete sanitized reports.
  mv "${PUBLISH_CYPRESS_DIR}/cypress-output.log" "${ARTIFACT_DIR}/cypress-output.log" || return 1
  shopt -s nullglob
  for file in "${PUBLISH_CYPRESS_DIR}"/junit_upgrade_legacy_state_verify-*.xml; do
    mv "${file}" "${ARTIFACT_DIR}/$(basename "${file}")" || return 1
  done
  shopt -u nullglob
  rm -rf "${PUBLISH_CYPRESS_DIR}"
  PUBLISH_CYPRESS_DIR=""
  rm -rf "${RAW_CYPRESS_DIR}"
  RAW_CYPRESS_DIR=""
  RAW_CYPRESS_OUTPUT=""
}
discard_cypress_artifacts() {
  rm -rf "${RAW_CYPRESS_DIR}" "${PUBLISH_CYPRESS_DIR}"
  RAW_CYPRESS_DIR=""
  PUBLISH_CYPRESS_DIR=""
  rm -f "${RAW_CYPRESS_OUTPUT}" "${ARTIFACT_DIR}"/cypress-output.log \
    "${ARTIFACT_DIR}"/junit_upgrade_legacy_state_verify-*.xml \
    "${ARTIFACT_DIR}"/junit_upgrade_legacy_state_verify-*.xml.tmp
  rm -rf "${ARTIFACT_DIR}/videos" "${ARTIFACT_DIR}/screenshots"
}
registry_tag_present() {
  local route="$1" owner="$2" password="$3" organization="$4" repository="$5"
  local token host
  host="${route#https://}"
  token="$(curl -sk --fail --get -u "${owner}:${password}" --data-urlencode "service=${host}" --data-urlencode "scope=repository:${organization}/${repository}:pull" "${route}/v2/auth" | jq -r '.token // .access_token // empty' || true)"
  [[ -n "${token}" ]] || return 1
  curl -sk --fail -H "Authorization: Bearer ${token}" "${route}/v2/${organization}/${repository}/tags/list" | jq -e '.tags | index("upgrade-legacy") != null' >/dev/null
}
restore_trace() { [[ "$1" == true ]] && set -x; return 0; }
[[ "${STRICT}" == true || "${STRICT}" == false ]] || fail "QUAY_UPGRADE_LEGACY_CYPRESS_STRICT must be true or false"
[[ -s "${STATE_FILE}" && -s "${ROUTE_FILE}" ]] || fail "missing persisted legacy state or Quay route"
# shellcheck disable=SC1090
source "${STATE_FILE}"
ROUTE="$(<"${ROUTE_FILE}")"
[[ "${ROUTE}" =~ ^https://[^/]+$ ]] || fail "Quay route must be a bare HTTPS endpoint"

registry_tag_present "${ROUTE}" "${OWNER}" "${OWNER_PASSWORD}" "${ORG}" "${REPOSITORY}" \
  || fail "persisted image tag is missing after upgrade"

prepare_cypress_dependencies

cat > quay-api-tests/cypress/e2e/upgrade_legacy_state_verify.cy.js <<'EOF'
const endpoint = Cypress.env("UPGRADE_ROUTE");
const owner = Cypress.env("UPGRADE_OWNER");
const password = Cypress.env("UPGRADE_PASSWORD");
const member = Cypress.env("UPGRADE_MEMBER");
const org = Cypress.env("UPGRADE_ORG");
const repository = Cypress.env("UPGRADE_REPOSITORY");
const team = Cypress.env("UPGRADE_TEAM");
const robot = Cypress.env("UPGRADE_ROBOT");
let authorization = "";
const request = (method, path, body) => cy.request({ method, url: `${endpoint}${path}`, headers: { authorization, "Content-Type": "application/json" }, body });
describe("legacy Quay upgrade persisted state verification", () => {
  before(() => cy.create_quay_oauth_token(endpoint, owner, password, "upgrade-state-verify").then((token) => { authorization = `Bearer ${token}`; }));
  it("requires the source state after the OLM update", () => {
    request("GET", `/api/v1/organization/${org}`).its("status").should("eq", 200);
    request("GET", `/api/v1/repository/${org}/${repository}`).then((response) => { expect(response.status).to.eq(200); expect(response.body.namespace).to.eq(org); expect(response.body.name).to.eq(repository); });
    request("GET", `/api/v1/organization/${org}/robots/${robot}`).its("status").should("eq", 200);
    request("GET", `/api/v1/organization/${org}/team/${team}/members`).then((response) => { expect(response.status).to.eq(200); expect(response.body.members.map((item) => item.name)).to.include(member); });
    request("GET", `/api/v1/repository/${org}/${repository}/permissions/team/${team}`).then((response) => { expect(response.status).to.eq(200); expect(response.body.role).to.eq("write"); });
    // An assertion failure aborts this Cypress command queue before DELETE.
    request("DELETE", `/api/v1/organization/${org}`).its("status").should("eq", 204);
  });
});
EOF

rc=0
rm -f "${ARTIFACT_DIR}"/junit_upgrade_legacy_state_verify-*.xml
RAW_CYPRESS_DIR="$(mktemp -d "/tmp/quay-upgrade-legacy-state-verify.raw.XXXXXX")" || fail "could not create private Cypress staging directory"
RAW_CYPRESS_OUTPUT="${RAW_CYPRESS_DIR}/cypress-output.log"
if (cd quay-api-tests && CYPRESS_UPGRADE_ROUTE="${ROUTE}" CYPRESS_UPGRADE_OWNER="${OWNER}" CYPRESS_UPGRADE_PASSWORD="${OWNER_PASSWORD}" CYPRESS_UPGRADE_MEMBER="${MEMBER}" CYPRESS_UPGRADE_ORG="${ORG}" CYPRESS_UPGRADE_REPOSITORY="${REPOSITORY}" CYPRESS_UPGRADE_TEAM="${TEAM}" CYPRESS_UPGRADE_ROBOT="${ROBOT}" NO_COLOR=1 node_modules/.bin/cypress run -b electron --spec cypress/e2e/upgrade_legacy_state_verify.cy.js --reporter mocha-junit-reporter --reporter-options "mochaFile=${RAW_CYPRESS_DIR}/junit_upgrade_legacy_state_verify-[hash].xml" --config "videosFolder=${RAW_CYPRESS_DIR}/videos,screenshotsFolder=${RAW_CYPRESS_DIR}/screenshots") > "${RAW_CYPRESS_OUTPUT}" 2>&1; then
  rc=0
else
  rc=$?
fi
publish_sanitized_cypress_artifacts || { discard_cypress_artifacts; fail "could not sanitize Cypress artifacts"; }
echo "Legacy upgrade verification Cypress run: exit code ${rc}"
[[ "${STRICT}" == false || "${rc}" -eq 0 ]] || fail "legacy upgrade verification Cypress failed"
[[ "${STRICT}" == false ]] || strict_junit_success "${ARTIFACT_DIR}/junit_upgrade_legacy_state_verify-*.xml" \
  || fail "legacy upgrade verification JUnit output is missing, empty, malformed, skipped, or failed"
restore_trace "${WAS_TRACING}"
