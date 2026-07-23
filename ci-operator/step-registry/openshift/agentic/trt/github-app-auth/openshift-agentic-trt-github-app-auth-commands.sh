#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CRED_DIR="/var/run/github-token"

echo "=== TRT GitHub App Auth ==="

APP_ID_FILE="${CRED_DIR}/app-id"
PRIVATE_KEY="${CRED_DIR}/private-key"

[[ -f "${APP_ID_FILE}" ]] || { echo "ERROR: ${APP_ID_FILE} not found."; exit 1; }
[[ -f "${PRIVATE_KEY}" ]] || { echo "ERROR: ${PRIVATE_KEY} not found."; exit 1; }

APP_ID=$(cat "${APP_ID_FILE}")

generate_jwt() {
    local exp_seconds=${1:-600}
    local now hdr pay sig
    now=$(date +%s)
    hdr=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    pay=$(echo -n "{\"iat\":$((now - 60)),\"exp\":$((now + exp_seconds)),\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    sig=$(echo -n "${hdr}.${pay}" | openssl dgst -sha256 -sign "${PRIVATE_KEY}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    echo "${hdr}.${pay}.${sig}"
}

generate_token() {
    local installation_id=$1
    local jwt token
    jwt=$(generate_jwt 600)

    token=$(curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 \
        -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${installation_id}/access_tokens" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")

    [[ -n "${token}" ]] || return 1
    echo "${token}"
}

# Resolve app slug (used by review-responder for bot identity)
APP_SLUG=$(curl -sf --connect-timeout 10 --max-time 15 \
    -H "Authorization: Bearer $(generate_jwt 120)" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('slug',''))")
[[ -n "${APP_SLUG}" ]] || { echo "ERROR: Failed to resolve app slug from /app endpoint."; exit 1; }
echo "${APP_SLUG}[bot]" > "${SHARED_DIR}/gh-app-bot-login"
echo "App slug: ${APP_SLUG} (bot login: ${APP_SLUG}[bot])"

IFS=',' read -ra PAIRS <<< "${GITHUB_APP_TOKEN_OUTPUTS}"
for pair in "${PAIRS[@]}"; do
    id_file="${pair%%:*}"
    output_name="${pair##*:}"

    [[ "${id_file}" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "ERROR: Invalid id_file name '${id_file}'."; exit 1; }
    [[ "${output_name}" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo "ERROR: Invalid output_name '${output_name}'."; exit 1; }

    id_path="${CRED_DIR}/${id_file}"
    [[ -f "${id_path}" ]] || { echo "ERROR: Installation ID file ${id_path} not found."; exit 1; }

    installation_id=$(cat "${id_path}")
    [[ "${installation_id}" =~ ^[0-9]+$ ]] || { echo "ERROR: Installation ID from ${id_file} is not numeric."; exit 1; }
    echo "Generating token for ${id_file}..."

    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x
    token=$(generate_token "${installation_id}")
    [[ -n "${token}" ]] || { echo "ERROR: Failed to generate token for ${id_file}."; exit 1; }
    echo "${token}" > "${SHARED_DIR}/${output_name}"
    $WAS_TRACING && set -x

    echo "  Written to \${SHARED_DIR}/${output_name}"
done

echo "=== TRT GitHub App Auth Complete ==="
