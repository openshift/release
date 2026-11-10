#!/bin/bash
set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-operator-upgrade-verify-api"
mkdir -p "${ARTIFACT_DIR}"

fail() { echo "ERROR: $*" >&2; exit 1; }

for f in quayroute quay-admin-username quay-admin-password quay-upgrade-seed quay-upgrade-seed-robot-token; do
  [[ -s "${SHARED_DIR}/${f}" ]] || fail "missing ${SHARED_DIR}/${f}"
done
seed="$(<"${SHARED_DIR}/quay-upgrade-seed")"
field() { sed -n "s/^$1=//p" <<<"${seed}"; }
org="$(field org)"
repo="$(field repo)"
robot="$(field robot)"
tag="$(field tag)"
expected_digest="$(field digest)"
[[ -n "${org}" && -n "${repo}" && "${robot}" == "${org}+"* && -n "${tag}" && -n "${expected_digest}" ]] \
  || fail "incomplete seed record from quay-operator-upgrade-seed-api"
token="$(<"${SHARED_DIR}/quay-upgrade-seed-robot-token")"
route="$(<"${SHARED_DIR}/quayroute")"
host="${route#*://}"
work="$(mktemp -d)"
jar="${work}/cookies"
csrf=""

# api METHOD PATH: sets code; the response body is in ${work}/body.
api() {
  rm -f "${work}/body"
  code="$(curl -sk --max-time 60 -o "${work}/body" -w '%{http_code}' -b "${jar}" -c "${jar}" -X "$1" \
    -H "X-CSRF-Token: ${csrf}" "${route}$2")" || code=000
}
expect() {
  [[ "${code}" == "$1" ]] || fail "$2 returned HTTP ${code}: $(jq -r '.error_message // .detail // .message // empty' "${work}/body" 2>/dev/null | head -c 300)"
}
refresh_csrf() {
  csrf="$(curl -sk --max-time 60 -b "${jar}" -c "${jar}" "${route}/csrf_token" | jq -r '.csrf_token // empty')"
  [[ -n "${csrf}" ]] || fail "no CSRF token from ${route}/csrf_token"
}

# Same admin session as quay-operator-upgrade-seed-api; the password goes to curl on stdin.
refresh_csrf
code="$(U="$(<"${SHARED_DIR}/quay-admin-username")" P="$(<"${SHARED_DIR}/quay-admin-password")" \
  jq -n '{username: env.U, password: env.P}' |
  curl -sk --max-time 60 -o "${work}/body" -w '%{http_code}' -b "${jar}" -c "${jar}" -X POST \
    -H "X-CSRF-Token: ${csrf}" -H 'Content-Type: application/json' --data @- "${route}/api/v1/signin")" || code=000
expect 200 "admin signin"
refresh_csrf

api GET "/api/v1/organization/${org}"
expect 200 "organization ${org}"
api GET "/api/v1/repository/${org}/${repo}"
expect 200 "repository ${org}/${repo}"
api GET "/api/v1/organization/${org}/robots/${robot#*+}"
expect 200 "robot ${robot}"
api GET "/api/v1/repository/${org}/${repo}/permissions/user/${robot}"
expect 200 "${robot} permission on ${org}/${repo}"
role="$(jq -r '.role // empty' "${work}/body")"
[[ "${role}" == write ]] || fail "${robot} has role '${role}' on ${org}/${repo}, expected write"

# An authfile keeps the robot token off skopeo's argv.
authfile="${work}/auth.json"
(umask 077; A="$(printf '%s:%s' "${robot}" "${token}" | base64 -w0)" H="${host}" \
  jq -n '{auths: {(env.H): {auth: env.A}}}' >"${authfile}")
src="docker://${host}/${org}/${repo}:${tag}"
digest="$(skopeo inspect --retry-times 3 --tls-verify=false --authfile "${authfile}" --format '{{.Digest}}' "${src}")"
[[ "${digest}" == "${expected_digest}" ]] || fail "${src} has digest ${digest}, seeded ${expected_digest}"
skopeo copy --retry-times 3 --src-tls-verify=false --src-authfile "${authfile}" "${src}" "dir:${work}/pull"

printf 'digest=%s\n' "${digest}" >"${ARTIFACT_DIR}/verified.txt"
echo "Verified ${org}/${repo}:${tag} (${digest}), robot ${robot} and its write role survived the upgrade."
