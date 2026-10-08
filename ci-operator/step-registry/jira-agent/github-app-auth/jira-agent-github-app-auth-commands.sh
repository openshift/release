#!/bin/bash
set -euo pipefail

# Write the github-app-auth shell library to SHARED_DIR for the process step to source.
cat > "${SHARED_DIR}/github-app-auth.sh" << 'EOF'
#!/bin/bash
# Generate short-lived GitHub App installation access tokens.
#
# Usage:
#   source github-app-auth.sh
#   TOKEN=$(generate_github_token <installation_id>)
#
# Environment:
#   GITHUB_APP_CREDS_DIR  Directory containing 'app-id' and 'private-key' files.
#                         Default: /var/run/claude-code-service-account

: "${GITHUB_APP_CREDS_DIR:=/var/run/claude-code-service-account}"

# generate_github_token <installation_id>
#
# Builds an RS256 JWT from the App credentials, exchanges it with GitHub for
# an installation access token, and prints the token to stdout.
# Returns 1 on missing args/files, 2 on API failure.
generate_github_token() {
  local install_id="$1"
  local app_id_file="${GITHUB_APP_CREDS_DIR}/app-id"
  local key_file="${GITHUB_APP_CREDS_DIR}/private-key"

  # --- validate inputs ---
  if [[ -z "$install_id" ]]; then
    echo "ERROR: generate_github_token requires an installation ID argument" >&2
    return 1
  fi
  if [[ ! -f "$app_id_file" ]]; then
    echo "ERROR: App ID file not found: $app_id_file" >&2
    return 1
  fi
  if [[ ! -f "$key_file" ]]; then
    echo "ERROR: Private key file not found: $key_file" >&2
    return 1
  fi

  # --- suppress tracing to protect credentials ---
  local _was_tracing=false
  [[ $- == *x* ]] && _was_tracing=true
  set +x

  # --- build JWT (RS256) ---
  local app_id now header payload signature jwt
  app_id=$(< "$app_id_file")
  now=$(date +%s)

  header=$(echo -n '{"alg":"RS256","typ":"JWT"}' \
    | base64 | tr -d '=\n' | tr '/+' '_-')
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 600))" "$app_id" \
    | base64 | tr -d '=\n' | tr '/+' '_-')
  signature=$(printf '%s.%s' "$header" "$payload" \
    | openssl dgst -sha256 -sign "$key_file" \
    | base64 | tr -d '=\n' | tr '/+' '_-') || {
    echo "ERROR: failed to sign GitHub App JWT" >&2
    $_was_tracing && set -x || true
    return 1
  }
  jwt="${header}.${payload}.${signature}"

  # --- exchange JWT for installation token ---
  local response token
  if ! response=$(curl -fsS -X POST \
    --connect-timeout 10 --max-time 30 \
    -H "Authorization: Bearer ${jwt}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${install_id}/access_tokens" 2>&1); then
    echo "ERROR: GitHub API request failed: ${response}" >&2
    $_was_tracing && set -x || true
    return 2
  fi

  if ! token=$(echo "$response" | jq -re '.token // empty' 2>/dev/null); then
    echo "ERROR: No token in GitHub API response: ${response}" >&2
    $_was_tracing && set -x || true
    return 2
  fi

  $_was_tracing && set -x || true
  echo "$token"
}
EOF

echo "github-app-auth.sh written to SHARED_DIR"
