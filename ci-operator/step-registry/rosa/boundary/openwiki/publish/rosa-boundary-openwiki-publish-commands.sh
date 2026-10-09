#!/usr/bin/env bash
set -euo pipefail

repo=openshift-online/rosa-boundary
base=main
branch=openwiki/update
production_job=periodic-ci-openshift-online-rosa-boundary-main-openwiki-openwiki-update
case "${JOB_NAME:-}" in
  "$production_job") dry_run=false ;;
  rehearse-*-"$production_job") dry_run=true ;;
  *) echo "Refusing to publish from unexpected job: ${JOB_NAME:-<unset>}" >&2; exit 1 ;;
esac
app_id_file=/var/run/rosa-boundary-github-app-id/github-app-app-id
installation_id_file=/var/run/rosa-boundary-github-app-installation/github-app-installation-id
private_key_file=/var/run/rosa-boundary-github-app-key/github-app-pem

update_status=$(cat "${SHARED_DIR}/openwiki-exit-status")
[[ "$update_status" =~ ^[0-9]+$ ]] || { echo 'Invalid OpenWiki exit status' >&2; exit 1; }
patch_file="${SHARED_DIR}/openwiki-docs.patch"
if [[ ! -s "$patch_file" ]]; then
  echo 'No OpenWiki documentation changes to publish or validate.'
  exit "$update_status"
fi

if [[ "$dry_run" == false ]]; then
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
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT
if [[ "$dry_run" == false ]]; then
  cat > "$workdir/askpass" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *Password*) printf '%s\n' "$GITHUB_TOKEN" ;;
esac
EOF
  chmod 700 "$workdir/askpass"
  export GIT_ASKPASS="$workdir/askpass" GIT_TERMINAL_PROMPT=0
fi

# Do not reuse the worktree the model was allowed to modify. Only apply its
# generated docs patch to a clean clone with no agent-controlled git hooks.
git clone "https://github.com/${repo}.git" "$workdir/repo"
cd "$workdir/repo"
git config user.name 'OpenShift CI Bot'
git config user.email 'ci-bot@redhat.com'
if [[ "$dry_run" == true ]]; then
  # The prepare step already checked the PR and recorded its base choice.
  # Do not create a GitHub token or call the PR API during rehearsal.
  base_branch=$(cat "${SHARED_DIR}/openwiki-base-branch")
  case "$base_branch" in
    "$base") existing_pr='' ;;
    "$branch") existing_pr=rehearsal ;;
    *) echo 'Unexpected OpenWiki base branch.' >&2; exit 1 ;;
  esac
else
  existing_pr=$(gh pr list --repo "$repo" --base "$base" --head "$branch" \
    --state open --json number --jq '.[0].number // empty')
fi
if [[ -n "$existing_pr" ]]; then
  git fetch origin "$branch"
  git switch -c "$branch" "origin/${branch}"
  git merge --no-edit "origin/${base}"
else
  if git ls-remote --exit-code origin "refs/heads/${branch}" >/dev/null; then
    echo "${branch} exists without an open PR; inspect/remove the stale bot branch before rerunning." >&2
    exit 1
  fi
  git switch -c "$branch" "origin/${base}"
fi

git apply --index --binary "$patch_file"
while IFS= read -r -d '' path; do
  case "$path" in
    openwiki/*) ;;
    *) echo "Refusing unexpected OpenWiki patch path: ${path}" >&2; exit 1 ;;
  esac
done < <(git diff --cached --name-only -z)
if git diff --cached --quiet; then
  echo 'No OpenWiki documentation changes to publish.'
  exit "$update_status"
fi

git diff --cached --check
if [[ "$dry_run" == true ]]; then
  echo 'Rehearsal dry run: patch applies cleanly; skipping commit, push, and PR creation.'
  git diff --cached --stat
  exit "$update_status"
fi

openwiki_version=$(cat "${SHARED_DIR}/openwiki-version")
model_id=$(cat "${SHARED_DIR}/openwiki-model-id")
provider=$(cat "${SHARED_DIR}/openwiki-provider")
for value in "$openwiki_version" "$model_id" "$provider"; do
  if [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]]; then
    echo 'Invalid OpenWiki provenance metadata.' >&2
    exit 1
  fi
done
if [[ ! "${BUILD_ID:-}" =~ ^[0-9]+$ ]]; then
  echo 'Missing or invalid Prow build ID.' >&2
  exit 1
fi

pr_body=$(cat <<EOF
## OpenWiki documentation refresh

This PR updates the generated ROSA Boundary wiki under \`openwiki/\`. It comes from [OpenShift CI's scheduled Prow periodic](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/${JOB_NAME}), **not GitHub Actions**. Please review the generated documentation and source-backed claims before merging; application code and root agent guidance are outside this job's publishing scope.

### Run details

| | |
| --- | --- |
| Prow job | \`${JOB_NAME}\` |
| Build | [\`${BUILD_ID}\`](https://prow.ci.openshift.org/view/gs/test-platform-results/logs/${JOB_NAME}/${BUILD_ID}) |
| OpenWiki | \`v${openwiki_version}\` (\`openwiki code --update --print\`) |
| Configured model | \`${model_id}\` via \`${provider}\` |
| OpenWiki exit status | \`${update_status}\` |
EOF
)
if [[ "$update_status" != 0 ]]; then
  pr_body+=$'\n\n**Partial update:** OpenWiki exited unsuccessfully. This PR includes only pages completed before the failure; review them before merging.'
fi

git commit -m 'docs: update OpenWiki'
git push origin "HEAD:refs/heads/${branch}"
if [[ -n "$existing_pr" ]]; then
  pr_url="https://github.com/${repo}/pull/${existing_pr}"
  gh api -X PATCH "repos/${repo}/pulls/${existing_pr}" -f body="$pr_body" --silent
else
  pr_url=$(gh pr create --repo "$repo" --base "$base" --head "$branch" \
    --title 'docs: update OpenWiki' --body "$pr_body")
fi
echo "OpenWiki PR: ${pr_url}"
exit "$update_status"
