#!/bin/bash
set -euo pipefail
umask 077 # Write the token with restrictive permissions before populating it.

# Mint a short-lived aro-hcp-robot GitHub App installation token for
# ${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME} and write it to
# ${SHARED_DIR}/github-token for a downstream step to use.

GITHUB_APP_ID_PATH="${GITHUB_APP_ID_PATH:-/var/run/aro-hcp-robot/appid}"
GITHUB_APP_KEY_PATH="${GITHUB_APP_KEY_PATH:-/var/run/aro-hcp-robot/cert}"
GITHUB_REPO_OWNER="${GITHUB_REPO_OWNER:-Azure}"
GITHUB_REPO_NAME="${GITHUB_REPO_NAME:-ARO-HCP}"
TOKEN_OUTPUT="${SHARED_DIR}/github-token"

# Base64url-encode stdin without padding, as required for JWT segments.
b64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

for tool in openssl curl jq; do
    if ! command -v "${tool}" &>/dev/null; then
        echo "ERROR: ${tool} not found; cannot mint the GitHub App token." >&2
        exit 1
    fi
done

if [[ ! -f "${GITHUB_APP_ID_PATH}" || ! -f "${GITHUB_APP_KEY_PATH}" ]]; then
    echo "ERROR: aro-hcp-robot App credentials not found; cannot mint the GitHub App token." >&2
    exit 1
fi

app_id=$(cat "${GITHUB_APP_ID_PATH}")
now=$(date +%s)
iat=$((now - 60)) # backdate slightly to tolerate clock skew
exp=$((now + 540)) # GitHub caps App JWTs at 10 minutes; use 9

header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "${iat}" "${exp}" "${app_id}" | b64url)
unsigned="${header}.${payload}"

signature=$(printf '%s' "${unsigned}" | openssl dgst -sha256 -sign "${GITHUB_APP_KEY_PATH}" -binary | b64url) || true
if [[ -z "${signature}" ]]; then
    echo "ERROR: could not sign the GitHub App JWT." >&2
    exit 1
fi
jwt="${unsigned}.${signature}"

installation=$(curl --silent --fail-with-body \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}/installation") || true
installation_id=$(jq -r '.id // empty' <<<"${installation:-}")
if [[ -z "${installation_id}" ]]; then
    echo "ERROR: could not resolve the GitHub App installation for ${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}." >&2
    exit 1
fi

# The downstream step creates/updates/deletes PR comments, so ask for the
# smallest permission set that allows write permissions to issues and pull_requests.
wanted_permissions='["issues","pull_requests"]'
permissions=$(jq -c --argjson wanted "${wanted_permissions}" \
    '(.permissions // {}) | with_entries(select(.value == "write" and ((.key as $k | $wanted | index($k)) != null)))' \
    <<<"${installation}")
if [[ -z "${permissions}" || "${permissions}" == "{}" ]]; then
    echo "ERROR: the installation grants no write access to ${wanted_permissions}." >&2
    exit 1
fi

# Exit just before posting so that pj-rehearse can test everything above this line
if [[ -n "${REPO_OWNER:-}${REPO_NAME:-}" \
    && "${REPO_OWNER:-}/${REPO_NAME:-}" != "${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}" ]]; then
    echo "This job runs for ${REPO_OWNER:-}/${REPO_NAME:-}, not ${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}. Verified the App credentials, but token minting will be skipped." >&2
    exit 0
fi

# Scope the token to the single repository the comment is posted on.
token_request=$(jq -cn --arg repo "${GITHUB_REPO_NAME}" --argjson permissions "${permissions}" \
    '{repositories: [$repo], permissions: $permissions}')
# example token_request output: {"repositories":["ARO-HCP"],"permissions":{"issues":"write","pull_requests":"write"}}

token=$(curl --silent --fail-with-body -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    --data "${token_request}" \
    "https://api.github.com/app/installations/${installation_id}/access_tokens" \
    | jq -r '.token // empty') || true
if [[ -z "${token}" ]]; then
    echo "ERROR: could not mint the GitHub App installation token." >&2
    exit 1
fi

touch "${TOKEN_OUTPUT}"
printf '%s' "${token}" > "${TOKEN_OUTPUT}"
echo "Wrote GitHub App installation token to ${SHARED_DIR}/github-token" >&2
