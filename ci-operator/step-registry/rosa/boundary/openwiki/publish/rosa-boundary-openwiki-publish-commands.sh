#!/usr/bin/env bash
# Never trace GitHub App credentials.
set +x
set -euo pipefail

repo=${TARGET_REPO:?}
base=${TARGET_BASE_BRANCH:?}
branch=${TARGET_UPDATE_BRANCH:?}
production_job=${TARGET_PERIODIC_JOB:?}
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid OpenWiki repository.' >&2; exit 1; }
[[ "$production_job" =~ ^periodic-ci-[a-z0-9-]+$ ]] || { echo 'Invalid scheduled periodic job name.' >&2; exit 1; }
git check-ref-format --branch "$base" >/dev/null
git check-ref-format --branch "$branch" >/dev/null
[[ "$base" != "$branch" ]] || { echo 'OpenWiki update branch must differ from the base branch.' >&2; exit 1; }
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
prepared_pr=$(cat "${SHARED_DIR}/openwiki-prepared-pr")
[[ "$prepared_pr" == none || "$prepared_pr" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid prepared OpenWiki PR identity.' >&2; exit 1; }

for file in "$app_id_file" "$installation_id_file" "$private_key_file"; do
  if [[ ! -s "$file" ]]; then
    echo "Missing GitHub App credential at ${file}" >&2
    exit 1
  fi
done

# Rehearsals still need authenticated private source access, but their token
# cannot write contents or PRs. Only the exact production job gets write scope.
permission='read'
if [[ "$dry_run" == false ]]; then
  permission='write'
fi
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
  --data "$(jq -nc --arg repository "${repo#*/}" --arg permission "$permission" \
    '{repositories:[$repository],permissions:{contents:$permission,pull_requests:$permission}}')" \
  "https://api.github.com/app/installations/$(cat "$installation_id_file")/access_tokens" \
  | jq -er '.token')
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

# Do not reuse the worktree the model was allowed to modify. Only apply its
# generated docs patch to a clean clone with no agent-controlled git hooks.
git clone "https://github.com/${repo}.git" "$workdir/repo"
cd "$workdir/repo"
git config user.name 'OpenShift CI Bot'
git config user.email 'ci-bot@redhat.com'
if [[ "$dry_run" == true ]]; then
  # The prepare step already checked the PR and recorded its base choice.
  # Rehearsals use the read-only token for Git only, without PR API calls.
  base_branch=$(cat "${SHARED_DIR}/openwiki-base-branch")
  case "$base_branch" in
    "$base") existing_pr='' ;;
    "$branch") existing_pr=rehearsal ;;
    *) echo 'Unexpected OpenWiki base branch.' >&2; exit 1 ;;
  esac
else
  existing_pr=$(gh pr list --repo "$repo" --base "$base" --head "$branch" \
    --state open --json number,headRepository \
    --jq "map(select(.headRepository.nameWithOwner == \"${repo}\"))[0].number // empty")
  if [[ "${existing_pr:-none}" != "$prepared_pr" ]]; then
    echo 'OpenWiki PR changed since preparation; refusing to publish.' >&2
    exit 1
  fi
fi
if [[ -n "$existing_pr" ]]; then
  git fetch origin "$branch"
  expected_branch_sha=$(git rev-parse --verify "refs/remotes/origin/${branch}^{commit}")
  git switch -c "$branch" "origin/${branch}"
  if [[ "$dry_run" == true ]]; then
    git merge --no-commit --no-ff "origin/${base}"
  else
    git merge --no-edit "origin/${base}"
  fi
else
  # Capture the current tip before starting from main. A closed PR can leave
  # this branch behind; only replace the exact tip we saw, never a newer push.
  remote_ref=$(git ls-remote origin "refs/heads/${branch}")
  if [[ -n "$remote_ref" ]]; then
    expected_branch_sha=${remote_ref%%$'\t'*}
  else
    expected_branch_sha=''
  fi
  git switch -c "$branch" "origin/${base}"
fi
if [[ -n "$expected_branch_sha" && ! "$expected_branch_sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo 'Unexpected bot branch revision.' >&2
  exit 1
fi

# A rehearsal's uncommitted merge is the trusted baseline, not generated
# documentation. Compare against its tree so source merges are not published.
patch_base=$(git write-tree)
git apply --index --binary "$patch_file"
while IFS= read -r -d '' path; do
  case "$path" in
    openwiki/*) ;;
    *) echo "Refusing unexpected OpenWiki patch path: ${path}" >&2; exit 1 ;;
  esac
done < <(git diff --cached --no-renames --name-only -z "$patch_base")
if git diff --cached --quiet "$patch_base"; then
  echo 'No OpenWiki documentation changes to publish.'
  exit "$update_status"
fi

# Markdown uses two trailing spaces for hard line breaks. Keep the other
# whitespace checks, and still reject trailing spaces in non-Markdown files.
git -c core.whitespace=-blank-at-eol diff --cached --check "$patch_base" -- \
  ':(glob)openwiki/*.md' ':(glob)openwiki/**/*.md'
git diff --cached --check "$patch_base" -- \
  ':(exclude,glob)openwiki/*.md' ':(exclude,glob)openwiki/**/*.md'
if [[ "$dry_run" == true ]]; then
  echo 'Rehearsal dry run: patch applies cleanly; skipping commit, push, and PR creation.'
  git diff --cached --stat "$patch_base"
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

This PR updates the generated wiki for \`${repo}\` under \`openwiki/\`. It comes from [OpenShift CI's scheduled Prow periodic](https://prow.ci.openshift.org/job-history/gs/test-platform-results/logs/${JOB_NAME}), **not GitHub Actions**. Please review the generated documentation and source-backed claims before merging; application code and root agent guidance are outside this job's publishing scope.

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
pr_title="docs: Scheduled OpenWiki update ($(date -u +%F))"

# A PR may have opened, closed, or been replaced while generating/applying
# docs. Never take over a new PR or publish back to a closed one.
current_pr=$(gh pr list --repo "$repo" --base "$base" --head "$branch" \
  --state open --json number,headRepository \
  --jq "map(select(.headRepository.nameWithOwner == \"${repo}\"))[0].number // empty")
if [[ "${current_pr:-none}" != "$prepared_pr" ]]; then
  echo 'OpenWiki PR changed during this run; refusing to publish.' >&2
  exit 1
fi
git commit -m 'docs: update OpenWiki'
# Lease every push, including existing PRs: a normal push could recreate a
# concurrently deleted branch or overwrite a rewind even though it is a FF.
git push --force-with-lease="refs/heads/${branch}:${expected_branch_sha}" \
  origin "HEAD:refs/heads/${branch}"
if [[ -n "$existing_pr" ]]; then
  pr_url="https://github.com/${repo}/pull/${existing_pr}"
  gh api -X PATCH "repos/${repo}/pulls/${existing_pr}" -f title="$pr_title" -f body="$pr_body" --silent
else
  pr_url=$(gh pr create --repo "$repo" --base "$base" --head "$branch" \
    --title "$pr_title" --body "$pr_body")
fi
echo "OpenWiki PR: ${pr_url}"
exit "$update_status"
