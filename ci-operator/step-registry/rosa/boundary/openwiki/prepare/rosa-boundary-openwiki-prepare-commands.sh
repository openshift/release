#!/usr/bin/env bash
set -euo pipefail

repo=${TARGET_REPO:?}
base=${TARGET_BASE_BRANCH:?}
branch=${TARGET_UPDATE_BRANCH:?}
umask 077
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid OpenWiki repository.' >&2; exit 1; }
git check-ref-format --branch "$base" >/dev/null
git check-ref-format --branch "$branch" >/dev/null
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
# The ci-operator entrypoint uploads SHARED_DIR as a Kubernetes Secret after
# this step. Pass only a repository-scoped, read-only token (not a Git bundle
# or the App key). Do not persist a token until its scope has been verified.
# Accept opaque legacy and stateless ghs_ tokens; the latter contain JWT dots
# and URL-safe hyphens. Reject characters that could inject curl config lines.
token_file="${SHARED_DIR}/openwiki-read-token"
handoff=false
cleanup() {
  if [[ "$handoff" == false ]]; then
    if [[ -s "$token_file" ]]; then
      printf 'header = "Authorization: Bearer %s"\n' "$(cat "$token_file")" |
        curl -fsS -o /dev/null -X DELETE -H 'Accept: application/vnd.github+json' \
          --config - https://api.github.com/installation/token ||
        echo 'Unable to confirm read token revocation after prepare failure.' >&2
    fi
    rm -f "$token_file" "${SHARED_DIR}/openwiki-base-branch"
  fi
}
trap cleanup EXIT
curl -fsS -X POST -H "Authorization: Bearer ${jwt}" \
  -H 'Accept: application/vnd.github+json' -H 'Content-Type: application/json' \
  --data "$(jq -nc --arg repository "${repo#*/}" '{repositories:[$repository],permissions:{contents:"read",pull_requests:"read"}}')" \
  "https://api.github.com/app/installations/$(cat "$installation_id_file")/access_tokens" \
  | jq -er --arg repo "$repo" '
      select(.repository_selection == "selected" and
        (.repositories | length) == 1 and .repositories[0].full_name == $repo and
        .permissions.contents == "read" and .permissions.pull_requests == "read" and
        ((.permissions | keys - ["contents", "metadata", "pull_requests"]) | length) == 0 and
        (.permissions.metadata == null or .permissions.metadata == "read") and
        (.token | type) == "string" and (.token | test("^ghs_[A-Za-z0-9_.-]+$"))) | .token
    ' > "$token_file" || { rm -f "$token_file"; echo 'GitHub token scope verification failed.' >&2; exit 1; }

existing_pr=$(GH_TOKEN="$(cat "$token_file")" gh pr list --repo "$repo" --base "$base" --head "$branch" \
  --state open --json number --jq '.[0].number // empty')
if [[ -n "$existing_pr" ]]; then
  printf '%s\n' "$branch" > "${SHARED_DIR}/openwiki-base-branch"
else
  # A closed PR may leave the bot branch behind. Start a fresh update from the
  # target base instead; publish replaces the stale branch only on a real run.
  printf '%s\n' "$base" > "${SHARED_DIR}/openwiki-base-branch"
fi
handoff=true
