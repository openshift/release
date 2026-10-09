#!/usr/bin/env bash
set -euo pipefail

repo=openshift-online/rosa-boundary
base=main
branch=openwiki/update
app_id_file=/var/run/rosa-boundary-github-app-id/github-app-app-id
installation_id_file=/var/run/rosa-boundary-github-app-installation/github-app-installation-id
private_key_file=/var/run/rosa-boundary-github-app-key/github-app-pem

for file in "$app_id_file" "$installation_id_file" "$private_key_file"; do
  if [[ ! -s "$file" ]]; then
    echo "Missing GitHub App credential at ${file}" >&2
    exit 1
  fi
done

now=$(date +%s)
header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' \
  "$((now - 60))" "$((now + 540))" "$(cat "$app_id_file")" \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=')
signature=$(printf '%s' "${header}.${payload}" \
  | openssl dgst -sha256 -sign "$private_key_file" \
  | openssl base64 -A | tr '+/' '-_' | tr -d '=')
jwt="${header}.${payload}.${signature}"
export GITHUB_TOKEN
GITHUB_TOKEN=$(curl -fsS -X POST -H "Authorization: Bearer ${jwt}" \
  -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' \
  --data '{"repositories":["rosa-boundary"],"permissions":{"contents":"write","pull_requests":"write"}}' \
  "https://api.github.com/app/installations/$(cat "$installation_id_file")/access_tokens" \
  | jq -er '.token')

# SHARED_DIR can carry flat files only. Pass the branch choice, not a checkout
# or credentials; the model step clones the public repository independently.
existing_pr=$(gh pr list --repo "$repo" --base "$base" --head "$branch" \
  --state open --json number --jq '.[0].number // empty')
if [[ -n "$existing_pr" ]]; then
  git ls-remote --exit-code "https://github.com/${repo}.git" "refs/heads/${branch}" >/dev/null
  printf '%s\n' "$branch" > "${SHARED_DIR}/openwiki-base-branch"
else
  if git ls-remote --exit-code "https://github.com/${repo}.git" "refs/heads/${branch}" >/dev/null; then
    echo "${branch} exists without an open PR; inspect/remove the stale bot branch before rerunning." >&2
    exit 1
  fi
  printf '%s\n' "$base" > "${SHARED_DIR}/openwiki-base-branch"
fi
