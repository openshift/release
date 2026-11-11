#!/bin/bash
set -euo pipefail

# The Cypress project and its supported API paths live in ci/quay-test-console.
# Do not enable tracing: this step creates two per-run passwords and persists
# them only long enough for the post-upgrade verification.
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-operator-upgrade-legacy-state"
mkdir -p "${ARTIFACT_DIR}"
umask 077
PHASE="${QUAY_UPGRADE_LEGACY_STATE_PHASE:-seed}"
STRICT="${QUAY_UPGRADE_LEGACY_CYPRESS_STRICT:-false}"
STATE_FILE="${SHARED_DIR}/quay-upgrade-legacy-state.env"
ROUTE_FILE="${SHARED_DIR}/quayroute"
PRESERVE_STATE=false
RAW_CYPRESS_OUTPUT=""

fail() { echo "ERROR: $*" >&2; exit 1; }
cleanup_sensitive_runtime() {
  rm -f "${RAW_CYPRESS_OUTPUT}" quay-api-tests/cypress/e2e/upgrade_legacy_state.cy.js
  rm -rf "${ARTIFACT_DIR}/videos" "${ARTIFACT_DIR}/screenshots"
  [[ "${PRESERVE_STATE}" == true ]] || rm -f "${STATE_FILE}"
}
trap cleanup_sensitive_runtime EXIT
new_legacy_password() {
  local password
  # tr exits with SIGPIPE once head has received the requested bytes. Capture
  # that intentionally bounded pipeline with pipefail disabled, then restore
  # it before returning to this strict shell.
  set +o pipefail
  password="$(LC_ALL=C tr -dc A-Za-z0-9 </dev/urandom | head -c 32)"
  set -o pipefail
  [[ ${#password} -eq 32 ]] || return 1
  printf '%s' "${password}"
}
strict_junit_success() {
  local pattern="$1" files=() file tests=0
  shopt -s nullglob
  files=( ${pattern} )
  shopt -u nullglob
  (( ${#files[@]} > 0 )) || return 1
  for file in "${files[@]}"; do
    [[ -s "${file}" ]] || return 1
    # mocha-junit-reporter emits a testsuite root and closing tag. Reject the
    # truncated report a count-only grep used to accept.
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
    -e 's@(Authorization(&quot;|")?[[:blank:]]*:[[:blank:]]*(&quot;|")?([A-Za-z]+[[:blank:]]+)?)[A-Za-z0-9._~+/=-]{16,}@\1<redacted:authorization>@Ig' \
    -e 's|(Authorizatio[n]:[[:blank:]]*([A-Za-z]+[[:blank:]]+)?)[A-Za-z0-9._~+/=-]{16,}|\1<redacted:authorization>|Ig' \
    -e 's|(X-CSRF-Token:[[:blank:]]*)[A-Za-z0-9._~+/=-]+|\1<redacted:csrf>|Ig' \
    -e 's|(_csrf_token=)[A-Za-z0-9._~+/=-]+|\1<redacted:session>|g' \
    -e 's#("[A-Za-z0-9_-]*(password|secret|token)(_?(key|code))?"[[:blank:]]*:[[:blank:]]*")([^"\\]|\\.)+#\1<redacted:value>#Ig' \
    | sed -u -e "s|${OWNER_PASSWORD}|<redacted:password>|g" -e "s|${MEMBER_PASSWORD}|<redacted:password>|g"
}
prepare_cypress_dependencies() {
  # The quay-test-console image contains the checkout but not its installed
  # Cypress dependencies. This adapter runs before quay-test-api-legacy, the
  # established consumer that performs this supported installation.
  (
    cd quay-api-tests
    [[ -f package.json ]] || fail "quay-api-tests package.json is missing"
    npm install --no-audit --no-fund
    [[ -x node_modules/.bin/cypress ]] || fail "Cypress binary was not installed in quay-api-tests"
  )
}
sanitize_cypress_artifacts() {
  local file
  rm -rf "${ARTIFACT_DIR}/videos" "${ARTIFACT_DIR}/screenshots"
  shopt -s nullglob
  for file in "${ARTIFACT_DIR}"/junit_upgrade_legacy_state-*.xml; do
    scrub_cypress_text < "${file}" > "${file}.tmp" || { rm -f "${file}.tmp"; return 1; }
    mv "${file}.tmp" "${file}"
  done
  shopt -u nullglob
}
registry_tag_present() {
  local route="$1" owner="$2" password="$3" organization="$4" repository="$5"
  local token host
  host="${route#https://}"
  # quay-api-tests old-UI consumer uses Quay /v2/auth: Basic only obtains a
  # token; the registry tags request is always Bearer authenticated.
  token="$(curl -sk --fail --get -u "${owner}:${password}" --data-urlencode "service=${host}" --data-urlencode "scope=repository:${organization}/${repository}:pull" "${route}/v2/auth" | jq -r '.token // .access_token // empty' || true)"
  [[ -n "${token}" ]] || return 1
  curl -sk --fail -H "Authorization: Bearer ${token}" "${route}/v2/${organization}/${repository}/tags/list" | jq -e '.tags | index("upgrade-legacy") != null' >/dev/null
}
restore_trace() { [[ "$1" == true ]] && set -x; return 0; }
[[ "${PHASE}" == seed || "${PHASE}" == verify ]] || fail "QUAY_UPGRADE_LEGACY_STATE_PHASE must be seed or verify"
[[ "${STRICT}" == true || "${STRICT}" == false ]] || fail "QUAY_UPGRADE_LEGACY_CYPRESS_STRICT must be true or false"
[[ -s "${ROUTE_FILE}" ]] || fail "missing Quay route from quay-operator-upgrade-prepare-e2e"
ROUTE="$(<"${ROUTE_FILE}")"
[[ "${ROUTE}" =~ ^https://[^/]+$ ]] || fail "Quay route must be a bare HTTPS endpoint"
HOST="${ROUTE#https://}"

register_user() {
  local username="$1" password="$2" cookies body csrf code
  cookies="$(mktemp)"
  body="$(mktemp)"
  csrf="$(curl -sk -c "${cookies}" "${ROUTE}/csrf_token" | jq -r '.csrf_token // empty' || true)"
  [[ -n "${csrf}" ]] || { rm -f "${cookies}" "${body}"; fail "could not obtain CSRF token for legacy state user"; }
  code="$(jq -n --arg username "${username}" --arg password "${password}" \
    '{username:$username,password:$password,repeatPassword:$password,email:($username + "@example.invalid")}' | \
    curl -sk -o "${body}" -w '%{http_code}' -X POST "${ROUTE}/api/v1/user/" \
      -b "${cookies}" -H "X-CSRF-Token: ${csrf}" -H 'Content-Type: application/json' --data @- || true)"
  rm -f "${cookies}"
  [[ "${code}" == 200 ]] || { rm -f "${body}"; fail "registering legacy state user returned HTTP ${code}"; }
  rm -f "${body}"
}

write_cypress_spec() {
  cat > quay-api-tests/cypress/e2e/upgrade_legacy_state.cy.js <<'EOF'
const endpoint = Cypress.env("UPGRADE_ROUTE");
const owner = Cypress.env("UPGRADE_OWNER");
const password = Cypress.env("UPGRADE_PASSWORD");
const member = Cypress.env("UPGRADE_MEMBER");
const org = Cypress.env("UPGRADE_ORG");
const repository = Cypress.env("UPGRADE_REPOSITORY");
const team = Cypress.env("UPGRADE_TEAM");
const robot = Cypress.env("UPGRADE_ROBOT");
const phase = Cypress.env("UPGRADE_PHASE");
let authorization = "";

const request = (method, path, body) => cy.request({
  method,
  url: `${endpoint}${path}`,
  headers: { authorization, "Content-Type": "application/json" },
  body,
});

describe("legacy Quay upgrade persisted state", () => {
  before(() => {
    // This is the same supported Cypress UI helper used by quay-api-tests to
    // create a scoped OAuth token. It never writes the token to SHARED_DIR.
    cy.create_quay_oauth_token(endpoint, owner, password, "upgrade-state").then((token) => {
      authorization = `Bearer ${token}`;
    });
  });

  if (phase === "seed") {
    it("creates the source persisted state", () => {
      request("POST", "/api/v1/organization/", { name: org, email: `${org}@example.invalid`, recaptcha_response: "" })
        .its("status").should("eq", 201);
      request("POST", "/api/v1/repository", { repo_kind: "image", namespace: org, repository, visibility: "private", description: "legacy upgrade persistence" })
        .then((response) => {
          expect(response.status).to.eq(201);
          expect(response.body.namespace).to.eq(org);
          expect(response.body.name).to.eq(repository);
        });
      request("PUT", `/api/v1/organization/${org}/robots/${robot}`, {})
        .its("status").should("eq", 201);
      request("PUT", `/api/v1/organization/${org}/team/${team}`, { name: team, role: "member" })
        .then((response) => expect(response.status).to.eq(200));
      request("PUT", `/api/v1/organization/${org}/team/${team}/members/${member}`, {})
        .then((response) => expect(response.status).to.eq(200));
      request("PUT", `/api/v1/repository/${org}/${repository}/permissions/team/${team}`, { role: "write" })
        .then((response) => expect(response.status).to.eq(200));
    });
  } else {
    it("verifies every persisted API state before cleanup", () => {
      request("GET", `/api/v1/organization/${org}`).then((response) => expect(response.status).to.eq(200));
      request("GET", `/api/v1/repository/${org}/${repository}`).then((response) => {
        expect(response.status).to.eq(200);
        expect(response.body.namespace).to.eq(org);
        expect(response.body.name).to.eq(repository);
      });
      request("GET", `/api/v1/organization/${org}/robots/${robot}`).then((response) => expect(response.status).to.eq(200));
      request("GET", `/api/v1/organization/${org}/team/${team}/members`).then((response) => {
        expect(response.status).to.eq(200);
        expect(response.body.members.map((item) => item.name)).to.include(member);
      });
      request("GET", `/api/v1/repository/${org}/${repository}/permissions/team/${team}`).then((response) => {
        expect(response.status).to.eq(200);
        expect(response.body.role).to.eq("write");
      });
      // Cypress stops its command queue on any assertion failure above, so the
      // destructive cleanup is causally unreachable until every state check
      // has succeeded.
      request("DELETE", `/api/v1/organization/${org}`).then((response) => expect(response.status).to.eq(204));
    });
  }
});
EOF
}

run_cypress() {
  local rc=0
  rm -f "${ARTIFACT_DIR}"/junit_upgrade_legacy_state-*.xml
  RAW_CYPRESS_OUTPUT="$(mktemp "${ARTIFACT_DIR}/cypress-output.XXXXXX")" || return 1
  if (cd quay-api-tests && \
    CYPRESS_UPGRADE_ROUTE="${ROUTE}" \
    CYPRESS_UPGRADE_OWNER="${OWNER}" \
    CYPRESS_UPGRADE_PASSWORD="${OWNER_PASSWORD}" \
    CYPRESS_UPGRADE_MEMBER="${MEMBER}" \
    CYPRESS_UPGRADE_ORG="${ORG}" \
    CYPRESS_UPGRADE_REPOSITORY="${REPOSITORY}" \
    CYPRESS_UPGRADE_TEAM="${TEAM}" \
    CYPRESS_UPGRADE_ROBOT="${ROBOT}" \
    CYPRESS_UPGRADE_PHASE="${PHASE}" \
    NO_COLOR=1 node_modules/.bin/cypress run -b electron --spec cypress/e2e/upgrade_legacy_state.cy.js \
      --reporter mocha-junit-reporter \
      --reporter-options "mochaFile=${ARTIFACT_DIR}/junit_upgrade_legacy_state-[hash].xml" \
      --config "videosFolder=${ARTIFACT_DIR}/videos,screenshotsFolder=${ARTIFACT_DIR}/screenshots") > "${RAW_CYPRESS_OUTPUT}" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  scrub_cypress_text < "${RAW_CYPRESS_OUTPUT}" | tee "${ARTIFACT_DIR}/cypress-output.log"
  rm -f "${RAW_CYPRESS_OUTPUT}"
  RAW_CYPRESS_OUTPUT=""
  sanitize_cypress_artifacts || return 1
  echo "Legacy upgrade ${PHASE} Cypress run: exit code ${rc}"
  if [[ "${STRICT}" == true ]]; then
    [[ "${rc}" -eq 0 ]] || fail "legacy upgrade ${PHASE} Cypress failed"
    strict_junit_success "${ARTIFACT_DIR}/junit_upgrade_legacy_state-*.xml" \
      || fail "legacy upgrade ${PHASE} JUnit output is missing, empty, malformed, skipped, or failed"
  fi
}

if [[ "${PHASE}" == seed ]]; then
  [[ ! -e "${STATE_FILE}" ]] || fail "legacy state file already exists before seed"
  suffix="${BUILD_ID:-${UNIQUE_HASH:-$(date +%s)}}"
  suffix="$(printf '%s' "${suffix}" | tr -cd '0-9' | tail -c 12)"
  [[ -n "${suffix}" ]] || fail "cannot derive a safe legacy state suffix"
  OWNER="upgradeowner${suffix}"
  MEMBER="upgrademember${suffix}"
  ORG="upgradeorg${suffix}"
  REPOSITORY="upgraderepo${suffix}"
  TEAM="upgradeteam${suffix}"
  ROBOT="upgraderobot${suffix}"
  OWNER_PASSWORD="$(new_legacy_password)" || fail "could not generate owner password"
  MEMBER_PASSWORD="$(new_legacy_password)" || fail "could not generate member password"
  register_user "${OWNER}" "${OWNER_PASSWORD}"
  register_user "${MEMBER}" "${MEMBER_PASSWORD}"
  umask 077
  cat >"${STATE_FILE}" <<EOF
OWNER='${OWNER}'
OWNER_PASSWORD='${OWNER_PASSWORD}'
MEMBER='${MEMBER}'
MEMBER_PASSWORD='${MEMBER_PASSWORD}'
ORG='${ORG}'
REPOSITORY='${REPOSITORY}'
TEAM='${TEAM}'
ROBOT='${ROBOT}'
TAG='upgrade-legacy'
EOF
  chmod 600 "${STATE_FILE}"
  prepare_cypress_dependencies
  write_cypress_spec
  run_cypress
  # No shell trace and no credential-containing command output. The image/tag
  # is validated by the registry API before the OLM channel move continues.
  skopeo copy --dest-tls-verify=false --dest-creds "${OWNER}:${OWNER_PASSWORD}" \
    docker://registry.access.redhat.com/ubi9/ubi-micro@sha256:d3499a0896e2d6a1642f922615831bc5c2fd513bbb34f3446cabba530d9d54a2 \
    "docker://${HOST}/${ORG}/${REPOSITORY}:upgrade-legacy" >/dev/null
  registry_tag_present "${ROUTE}" "${OWNER}" "${OWNER_PASSWORD}" "${ORG}" "${REPOSITORY}" \
    || fail "pushed source image tag is not present"
  PRESERVE_STATE=true
else
  [[ -s "${STATE_FILE}" ]] || fail "missing persisted legacy state from seed"
  # The state file is written by this step under mode 0600; it contains only
  # the per-run users needed to authenticate the source and target checks.
  # shellcheck disable=SC1090
  source "${STATE_FILE}"
  registry_tag_present "${ROUTE}" "${OWNER}" "${OWNER_PASSWORD}" "${ORG}" "${REPOSITORY}" \
    || fail "persisted image tag is missing after upgrade"
  prepare_cypress_dependencies
  write_cypress_spec
  run_cypress
  rm -f "${STATE_FILE}"
fi

restore_trace "${WAS_TRACING}"
