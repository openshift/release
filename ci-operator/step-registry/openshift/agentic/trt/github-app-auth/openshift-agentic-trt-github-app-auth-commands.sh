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

generate_token() {
    local installation_id=$1
    local now iat exp header payload signature jwt token
    now=$(date +%s)
    iat=$((now - 60))
    exp=$((now + 600))
    header=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    payload=$(echo -n "{\"iat\":${iat},\"exp\":${exp},\"iss\":\"${APP_ID}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    signature=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -sign "${PRIVATE_KEY}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    jwt="${header}.${payload}.${signature}"

    token=$(curl -sf --connect-timeout 10 --max-time 30 --retry 3 --retry-delay 5 \
        -X POST \
        -H "Authorization: Bearer ${jwt}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app/installations/${installation_id}/access_tokens" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))")

    [[ -n "${token}" ]] || return 1
    echo "${token}"
}

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
