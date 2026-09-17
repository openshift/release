#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT GitHub App Auth ==="

CRED_DIR="/var/run/github-token"
APP_ID_FILE="${CRED_DIR}/app-id"
PRIVATE_KEY="${CRED_DIR}/private-key"

[[ -f "${APP_ID_FILE}" ]] || { echo "ERROR: ${APP_ID_FILE} not found."; exit 1; }
[[ -f "${PRIVATE_KEY}" ]] || { echo "ERROR: ${PRIVATE_KEY} not found."; exit 1; }

# Persist the output mapping so later steps can refresh without this env var.
echo "${GITHUB_APP_TOKEN_OUTPUTS}" > "${SHARED_DIR}/github-app-token-outputs"

# Step-registry refs only ship their own commands.sh, so the reusable token
# helpers have to live on SHARED_DIR for later steps to source.
cat > "${SHARED_DIR}/github-app-auth.sh" << 'HEREDOC_EOF'
#!/bin/bash
# TRT GitHub App token helpers. Source from later steps:
#   source "${SHARED_DIR}/github-app-auth.sh"
#
# GitHub App installation tokens always expire after 1 hour; GitHub does not
# allow a longer TTL. Long-running steps must refresh.

GITHUB_APP_CRED_DIR="${GITHUB_APP_CRED_DIR:-/var/run/github-token}"

generate_jwt() {
    local exp_seconds=${1:-600}
    local now hdr pay sig app_id
    app_id=$(tr -d '[:space:]' < "${GITHUB_APP_CRED_DIR}/app-id")
    now=$(date +%s)
    hdr=$(echo -n '{"alg":"RS256","typ":"JWT"}' | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    pay=$(echo -n "{\"iat\":$((now - 60)),\"exp\":$((now + exp_seconds)),\"iss\":\"${app_id}\"}" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
    sig=$(echo -n "${hdr}.${pay}" | openssl dgst -sha256 -sign "${GITHUB_APP_CRED_DIR}/private-key" | base64 | tr -d '=' | tr '/+' '_-' | tr -d '\n')
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

# Mint a fresh installation token for every mapping in github-app-token-outputs.
# Tokens are staged in a temp dir and only replace SHARED_DIR files after every
# mapping succeeds, so a mid-loop failure leaves existing files and exports as-is.
refresh_github_tokens() {
    local outputs_file="${SHARED_DIR}/github-app-token-outputs"
    local pairs pair id_file output_name id_path installation_id token tmpdir
    local was_tracing=false
    local -a staged=()

    [[ -f "${outputs_file}" ]] || {
        echo "ERROR: ${outputs_file} not found — github-app-auth step must run first" >&2
        return 1
    }

    tmpdir=$(mktemp -d) || return 1

    echo "Refreshing GitHub App installation tokens..."
    IFS=',' read -ra pairs <<< "$(cat "${outputs_file}")"
    for pair in "${pairs[@]}"; do
        id_file="${pair%%:*}"
        output_name="${pair##*:}"

        if [[ ! "${id_file}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            echo "ERROR: Invalid id_file name '${id_file}'." >&2
            rm -rf "${tmpdir}"
            return 1
        fi
        if [[ ! "${output_name}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            echo "ERROR: Invalid output_name '${output_name}'." >&2
            rm -rf "${tmpdir}"
            return 1
        fi

        id_path="${GITHUB_APP_CRED_DIR}/${id_file}"
        if [[ ! -f "${id_path}" ]]; then
            echo "ERROR: Installation ID file ${id_path} not found." >&2
            rm -rf "${tmpdir}"
            return 1
        fi

        installation_id=$(cat "${id_path}")
        if [[ ! "${installation_id}" =~ ^[0-9]+$ ]]; then
            echo "ERROR: Installation ID from ${id_file} is not numeric." >&2
            rm -rf "${tmpdir}"
            return 1
        fi
        echo "  Generating token for ${id_file}..."

        [[ $- == *x* ]] && was_tracing=true || was_tracing=false
        set +x
        token=$(generate_token "${installation_id}") || token=""
        if [[ -z "${token}" ]]; then
            ${was_tracing} && set -x
            echo "ERROR: Failed to generate token for ${id_file}." >&2
            rm -rf "${tmpdir}"
            return 1
        fi
        if ! echo "${token}" > "${tmpdir}/${output_name}"; then
            ${was_tracing} && set -x
            echo "ERROR: Failed to stage token for ${id_file}." >&2
            rm -rf "${tmpdir}"
            return 1
        fi
        staged+=("${output_name}")
        ${was_tracing} && set -x
    done

    for output_name in "${staged[@]}"; do
        if ! mv -f "${tmpdir}/${output_name}" "${SHARED_DIR}/${output_name}"; then
            echo "ERROR: Failed to install ${output_name}." >&2
            rm -rf "${tmpdir}"
            return 1
        fi
        echo "  Written to \${SHARED_DIR}/${output_name}"
    done
    rm -rf "${tmpdir}"

    [[ $- == *x* ]] && was_tracing=true || was_tracing=false
    set +x
    GH_FORK_TOKEN=$(cat "${SHARED_DIR}/gh-fork-token")
    export GH_FORK_TOKEN
    GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
    export GITHUB_TOKEN
    ${was_tracing} && set -x

    echo "GitHub App tokens refreshed"
}

# Read already-minted tokens from SHARED_DIR into the environment.
load_github_tokens() {
    local was_tracing=false
    [[ $- == *x* ]] && was_tracing=true || was_tracing=false
    set +x
    GH_FORK_TOKEN=$(cat "${SHARED_DIR}/gh-fork-token")
    export GH_FORK_TOKEN
    GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
    export GITHUB_TOKEN
    ${was_tracing} && set -x
}

# Point git at the token file so pushes pick up refreshes without re-exporting.
configure_github_git_credentials() {
    [[ "${EVAL_MODE:-}" == "true" ]] && return 0
    git config --global credential.helper "!f() { echo username=x-access-token; echo \"password=\$(cat ${SHARED_DIR}/gh-fork-token)\"; }; f"
}
HEREDOC_EOF
chmod +x "${SHARED_DIR}/github-app-auth.sh"

# shellcheck source=/dev/null
source "${SHARED_DIR}/github-app-auth.sh"

# Resolve app slug (used by review-responder for bot identity)
app_json=""
for attempt in 1 2 3 4; do
    app_json=$(curl -sf --connect-timeout 10 --max-time 15 \
        -H "Authorization: Bearer $(generate_jwt 120)" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/app") && break
    echo "GET https://api.github.com/app failed (attempt ${attempt}/4), retrying..."
    sleep $((attempt * 5))
done
[[ -n "${app_json}" ]] || {
    echo "ERROR: GET https://api.github.com/app failed after 4 attempts."
    exit 1
}
APP_SLUG=$(echo "${app_json}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('slug',''))")
[[ -n "${APP_SLUG}" ]] || { echo "ERROR: Failed to resolve app slug from /app endpoint."; exit 1; }
echo "${APP_SLUG}[bot]" > "${SHARED_DIR}/gh-app-bot-login"
echo "App slug: ${APP_SLUG} (bot login: ${APP_SLUG}[bot])"

refresh_github_tokens || { echo "ERROR: Failed to generate GitHub App tokens."; exit 1; }

echo "=== TRT GitHub App Auth Complete ==="
