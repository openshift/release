#!/usr/bin/env bash
# Never trace GitHub App credentials.
set +x
set -euo pipefail

repo=${TARGET_REPO:?}
base=${TARGET_BASE_BRANCH:?}
branch=${TARGET_UPDATE_BRANCH:?}
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid OpenWiki repository.' >&2; exit 1; }
git check-ref-format --branch "$base" >/dev/null
git check-ref-format --branch "$branch" >/dev/null
[[ "$base" != "$branch" ]] || { echo 'OpenWiki update branch must differ from the base branch.' >&2; exit 1; }
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
  --data "$(jq -nc --arg repository "${repo#*/}" '{repositories:[$repository],permissions:{contents:"read",pull_requests:"read"}}')" \
  "https://api.github.com/app/installations/$(cat "$installation_id_file")/access_tokens" \
  | jq -er '.token')

# Override any ambient gh token with this repository-scoped, read-only token.
export GH_TOKEN="$GITHUB_TOKEN"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
cat > "$workdir/askpass" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *Password*) printf '%s\n' "$GITHUB_TOKEN" ;;
esac
EOF
chmod 700 "$workdir/askpass"
export GIT_ASKPASS="$workdir/askpass" GIT_TERMINAL_PROMPT=0

# Ignore same-named branches in forks: only continue the target repo's own PR.
existing_pr=$(gh pr list --repo "$repo" --base "$base" --head "$branch" \
  --state open --json number,headRepository \
  --jq "map(select(.headRepository.nameWithOwner == \"${repo}\"))[0].number // empty")

# SHARED_DIR accepts flat files, not worktrees. Bundle the complete history of
# the base and, if its PR is open, update branch. Git bundles contain objects
# and refs only: no GitHub token, local config, hooks, or credential helper.
git clone --bare --single-branch --no-tags --branch "$base" \
  "https://github.com/${repo}.git" "$workdir/repo.git"
bundle_refs=("refs/heads/${base}")
base_branch=$base
if [[ -n "$existing_pr" ]]; then
  git -C "$workdir/repo.git" fetch --no-tags origin "refs/heads/${branch}:refs/heads/${branch}"
  bundle_refs+=("refs/heads/${branch}")
  base_branch=$branch
fi
# A closed PR's leftover branch is deliberately excluded; publish replaces
# that stale branch only on a production run, with force-with-lease.
git -C "$workdir/repo.git" bundle create "${SHARED_DIR}/openwiki-source.bundle" "${bundle_refs[@]}"
git -C "$workdir/repo.git" bundle verify "${SHARED_DIR}/openwiki-source.bundle" >/dev/null
printf '%s\n' "$base_branch" > "${SHARED_DIR}/openwiki-base-branch"
printf '%s\n' "${existing_pr:-none}" > "${SHARED_DIR}/openwiki-prepared-pr"
