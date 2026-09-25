#!/bin/bash
set -euo pipefail
umask 077 # Write the token with restrictive permissions before populating it.

# Mint a short-lived aro-hcp-robot GitHub App installation token for ${REPO_OWNER}/${REPO_NAME}
# writes the token to ${SHARED_DIR}/github-token for a downstream steps to use.

GITHUB_APP_ID_PATH="${GITHUB_APP_ID_PATH:-/var/run/aro-hcp-robot/appid}"
GITHUB_APP_KEY_PATH="${GITHUB_APP_KEY_PATH:-/var/run/aro-hcp-robot/cert}"
REPO_OWNER="${REPO_OWNER:-Azure}"
REPO_NAME="${REPO_NAME:-ARO-HCP}"
TOKEN_OUTPUT="${SHARED_DIR}/github-token"

# Base64url-encode stdin without padding, as required for JWT segments.
b64url() {
    openssl base64 -A | tr '+/' '-_' | tr -d '='
}

for tool in openssl curl jq; do
    if ! command -v "${tool}" &>/dev/null; then
        echo "WARNING: ${tool} not found. Skipping token minting." >&2
        exit 0
    fi
done

if [[ ! -f "${GITHUB_APP_ID_PATH}" || ! -f "${GITHUB_APP_KEY_PATH}" ]]; then
    echo "WARNING: aro-hcp-robot App credentials not found; skipping token minting." >&2
    exit 0
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
    echo "WARNING: could not sign the GitHub App JWT; PR comment will be skipped." >&2
    exit 0
fi
jwt="${unsigned}.${signature}"

installation_id=$(curl --silent --fail-with-body \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/installation" \
    | jq -r '.id // empty') || true
if [[ -z "${installation_id}" ]]; then
    echo "WARNING: could not resolve GitHub App installation for ${REPO_OWNER}/${REPO_NAME}; PR comment will be skipped." >&2
    exit 0
fi

token=$(curl --silent --fail-with-body -X POST \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${installation_id}/access_tokens" \
    | jq -r '.token // empty') || true
if [[ -z "${token}" ]]; then
    echo "WARNING: could not mint GitHub App installation token; PR comment will be skipped." >&2
    exit 0
fi

touch "${TOKEN_OUTPUT}"
printf '%s' "${token}" > "${TOKEN_OUTPUT}"
echo "Wrote GitHub App installation token to ${SHARED_DIR}/github-token" >&2
