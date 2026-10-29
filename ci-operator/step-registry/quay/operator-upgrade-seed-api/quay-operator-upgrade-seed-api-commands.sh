#!/bin/bash
set -euo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-operator-upgrade-seed-api"
mkdir -p "${ARTIFACT_DIR}"
SEED_IMAGE="${QUAY_UPGRADE_SEED_IMAGE:-}"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "${SEED_IMAGE}" =~ ^[^[:space:]@]+@(sha256:[a-f0-9]{64})$ ]] || fail "QUAY_UPGRADE_SEED_IMAGE must be image@sha256:<64 hex>"
expected_digest="${BASH_REMATCH[1]}"
for f in quayroute quay-admin-username quay-admin-password; do
  [[ -s "${SHARED_DIR}/${f}" ]] || fail "missing ${SHARED_DIR}/${f}"
done
route="$(<"${SHARED_DIR}/quayroute")"
host="${route#*://}"
work="$(mktemp -d)"
jar="${work}/cookies"
csrf=""

# api METHOD PATH [JSON]: sets code; the response body is in ${work}/body.
api() {
  local data=()
  (( $# > 2 )) && data=(--data "$3")
  code="$(curl -sk --max-time 60 -o "${work}/body" -w '%{http_code}' -b "${jar}" -c "${jar}" -X "$1" \
    -H "X-CSRF-Token: ${csrf}" -H 'Content-Type: application/json' "${data[@]}" "${route}$2")" || code=000
}
expect() {
  [[ "${code}" == "$1" ]] || fail "$2 returned HTTP ${code}: $(head -c 500 "${work}/body")"
}
refresh_csrf() {
  csrf="$(curl -sk --max-time 60 -b "${jar}" -c "${jar}" "${route}/csrf_token" | jq -r '.csrf_token // empty')"
  [[ -n "${csrf}" ]] || fail "no CSRF token from ${route}/csrf_token"
}

# The Quay API takes a session or OAuth token, not basic auth. Sign in as the
# admin quay-create-admin-user created; the password goes to curl on stdin.
refresh_csrf
code="$(U="$(<"${SHARED_DIR}/quay-admin-username")" P="$(<"${SHARED_DIR}/quay-admin-password")" \
  jq -n '{username: env.U, password: env.P}' |
  curl -sk --max-time 60 -o "${work}/body" -w '%{http_code}' -b "${jar}" -c "${jar}" -X POST \
    -H "X-CSRF-Token: ${csrf}" -H 'Content-Type: application/json' --data @- "${route}/api/v1/signin")" || code=000
expect 200 "admin signin"
# Signin rotates the session's CSRF token.
refresh_csrf

suffix="$(set +o pipefail; LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 8)"
org="upgradeseed${suffix}"
repo=seed
robot_short=pusher
robot="${org}+${robot_short}"
tag=seed

api POST /api/v1/organization/ "$(jq -cn --arg n "${org}" '{name: $n, email: ($n + "@example.com")}')"
expect 201 "creating organization ${org}"
api POST /api/v1/repository "$(jq -cn --arg o "${org}" --arg r "${repo}" '{namespace: $o, repository: $r, visibility: "private", description: "Quay upgrade seed"}')"
expect 201 "creating repository ${org}/${repo}"
api PUT "/api/v1/organization/${org}/robots/${robot_short}" '{}'
expect 201 "creating robot ${robot}"
token="$(jq -r '.token // empty' "${work}/body")"
[[ -n "${token}" ]] || fail "robot ${robot} was created without a token"
api PUT "/api/v1/repository/${org}/${repo}/permissions/user/${robot}" '{"role": "write"}'
expect 200 "granting ${robot} write on ${org}/${repo}"

# An authfile keeps the robot token off skopeo's argv.
authfile="${work}/auth.json"
(umask 077; A="$(printf '%s:%s' "${robot}" "${token}" | base64 -w0)" H="${host}" \
  jq -n '{auths: {(env.H): {auth: env.A}}}' >"${authfile}")
dest="docker://${host}/${org}/${repo}:${tag}"
skopeo copy --retry-times 3 --dest-tls-verify=false --dest-authfile "${authfile}" "docker://${SEED_IMAGE}" "${dest}"
digest="$(skopeo inspect --retry-times 3 --tls-verify=false --authfile "${authfile}" --format '{{.Digest}}' "${dest}")"
[[ "${digest}" == "${expected_digest}" ]] || fail "pushed ${dest} has digest ${digest}, expected ${expected_digest}"

cat >"${SHARED_DIR}/quay-upgrade-seed" <<EOF
org=${org}
repo=${repo}
robot=${robot}
tag=${tag}
digest=${digest}
EOF
printf '%s' "${token}" >"${SHARED_DIR}/quay-upgrade-seed-robot-token"
cp "${SHARED_DIR}/quay-upgrade-seed" "${ARTIFACT_DIR}/seed.txt"
echo "Seeded ${org}/${repo}:${tag} (${digest}) as robot ${robot}."
