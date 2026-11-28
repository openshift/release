#!/bin/bash
set +x
set -euo pipefail

# Never place the token in a remote URL or in traced command arguments.
export GH_TOKEN
GH_TOKEN=$(< /creds-github/token)
component=${RELEASE_COMPONENT}
repo="openshift-service-mesh/${component}"
supported_versions=(1.30 1.31)
case ${component} in
  istio|proxy|ztunnel) upstream_repo="istio/${component}" ;;
  *) echo "Unsupported RELEASE_COMPONENT: ${component}" >&2; exit 1 ;;
esac

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT

export GIT_CONFIG_GLOBAL="${workdir}/gitconfig"
# The helper reads the token from the environment when git asks for it.
git config --global credential.https://github.com.helper \
  '!f() { [ "$1" = get ] && printf "username=x-access-token\npassword=%s\n" "${GH_TOKEN}"; }; f'
if [[ ${component} == istio ]]; then
  # Take upstream's istio.deps during the merge; restore_istio_pins then
  # restores the downstream proxy/ztunnel pins.
  echo 'istio.deps merge=istio-deps' > "${workdir}/gitattributes"
  git config --global core.attributesFile "${workdir}/gitattributes"
  git config --global merge.istio-deps.name 'take upstream istio.deps'
  git config --global merge.istio-deps.driver 'cp %B %A'
fi

cd "${workdir}"
git init --quiet --bare repo.git
cd repo.git
git remote add midstream "https://github.com/${repo}.git"
git remote add upstream "https://github.com/${upstream_repo}.git"
# Fetch complete histories: shallow clones cannot establish ancestry reliably.
git fetch --no-tags midstream '+refs/heads/release-*:refs/remotes/midstream/release-*'

# is_ancestor behaves like git merge-base --is-ancestor, except that git errors
# fail the job instead of reading as "not an ancestor".
is_ancestor() {
  local status=0
  git merge-base --is-ancestor "$1" "$2" || status=$?
  if (( status > 1 )); then
    echo "ERROR: git merge-base --is-ancestor $1 $2 failed with status ${status}" >&2
    exit "${status}"
  fi
  return "${status}"
}

# find_cut_point prints the newest commit on the midstream y-stream branch, walking
# first parents from the tip, that does not contain first_after. First parents
# follow the order in which commits landed on the branch, so this is the last
# midstream state before any upstream change made after the branch point arrived.
find_cut_point() {
  local midstream_ref=$1 first_after=$2 commits commit
  if [[ -z ${first_after} ]]; then
    git rev-parse "${midstream_ref}"
    return
  fi
  commits=$(git rev-list --first-parent "${midstream_ref}")
  while read -r commit; do
    if ! is_ancestor "${first_after}" "${commit}"; then
      echo "${commit}"
      return
    fi
  done <<< "${commits}"
  echo "ERROR: every commit on ${midstream_ref} contains ${first_after}" >&2
  return 1
}

# restore_istio_pins keeps the downstream proxy/ztunnel pins from the cut point in
# the merged istio.deps, amending the merge commit if they differ from upstream's.
# merge_tag runs in a || list, where set -e is ignored, so every step checks its status.
restore_istio_pins() {
  local cut_point=$1
  git show "${cut_point}:istio.deps" > "${workdir}/downstream-deps" || return 1
  git show "HEAD^2:istio.deps" > "${workdir}/upstream-deps" || return 1
  jq -e --slurpfile downstream "${workdir}/downstream-deps" '
    reduce ["PROXY_REPO_SHA", "ZTUNNEL_REPO_SHA"][] as $name (. ;
      ($downstream[0] | map(select(.name == $name))) as $pin
      | if ($pin | length) != 1
          or ($pin[0].lastStableSHA | type) != "string"
          or ($pin[0].lastStableSHA | length) == 0
          or (map(select(.name == $name)) | length) != 1
        then error("Missing, duplicate, or invalid pin: " + $name)
        else map(if .name == $name then .lastStableSHA = $pin[0].lastStableSHA else . end)
        end)
  ' "${workdir}/upstream-deps" > "${workdir}/merged-deps" || return 1
  cp "${workdir}/merged-deps" istio.deps || return 1
  git add istio.deps || return 1
  if ! git diff --cached --quiet -- istio.deps; then
    git commit --quiet --amend --no-edit || return 1
  fi
}

# report_failure opens an issue for a z-stream branch that could not be created,
# unless one is already open. Nothing is pushed in that case, so the next run
# starts over and creates the branch once the cause is fixed.
report_failure() {
  local target=$1 tag=$2 details=$3 title existing
  title="Automatic creation of ${target} from upstream tag ${tag} failed"
  existing=$(gh issue list --repo "${repo}" --state open --search "\"${title}\" in:title" \
    --json number,title --jq "map(select(.title == \"${title}\"))[0].number // empty")
  if [[ -z ${existing} ]]; then
    gh issue create --repo "${repo}" --title "${title}" --body "${details}" >/dev/null
  fi
}

# merge_tag merges the upstream tag into the cut point in a scratch worktree and
# prints the resulting commit. Conflicts are never resolved here: the merge is
# abandoned and reported instead.
merge_tag() {
  local target=$1 tag=$2 cut_point=$3 branch_point=$4 upstream_ref=$5
  local worktree="${workdir}/worktree" conflicts merge_base merge_commit
  git worktree add --quiet --detach "${worktree}" "${cut_point}"
  (
    cd "${worktree}"
    if ! git merge --quiet --no-ff --no-edit --log \
        -m "Merge upstream tag ${tag} into ${target}" "refs/tags/${tag}" >&2; then
      conflicts=$(git diff --name-only --diff-filter=U)
      git merge --abort
      echo "Merging upstream tag ${tag} into ${target} failed; conflicting files: ${conflicts:-<none>}" >&2
      report_failure "${target}" "${tag}" "Merging upstream tag ${tag} into a branch from \
${cut_point} conflicts, so ${target} was not created. Conflicting files:

\`\`\`
${conflicts:-<none>}
\`\`\`

Resolve the merge in a new branch from ${cut_point} and push it as ${target}."
      exit 1
    fi
    if [[ ${component} == istio ]]; then
      restore_istio_pins "${cut_point}" || exit 1
    fi
    # Never publish a z-stream branch containing upstream changes made after its branch point.
    merge_base=$(git merge-base HEAD "${upstream_ref}")
    if [[ ${merge_base} != "${branch_point}" ]]; then
      echo "Expected the merge to share ${branch_point} with ${upstream_ref}, got ${merge_base}" >&2
      exit 1
    fi
    merge_commit=$(git rev-parse HEAD)
    if [[ $(git rev-parse HEAD^1) != "${cut_point}" ]]; then
      echo "Expected a merge commit with ${cut_point} as its first parent" >&2
      exit 1
    fi
    echo "${merge_commit}"
  ) || { git worktree remove --force "${worktree}"; return 1; }
  git worktree remove --force "${worktree}"
}

bot_login=
failed=0
for release_line in "${supported_versions[@]}"; do
  y_branch="release-${release_line}"
  midstream_ref="refs/remotes/midstream/${y_branch}"
  git show-ref --verify --quiet "${midstream_ref}" || continue
  # List tag names without fetching their histories; exclude prereleases.
  tag=$(git ls-remote --tags --refs upstream "refs/tags/${release_line}.*" |
    awk -F/ '$3 ~ /^[0-9]+\.[0-9]+\.[0-9]+$/ {print $3}' |
    sort -V | tail -n 1)
  [[ -n ${tag} ]] || continue
  target="release-${tag}"
  # Branches are only ever created complete, so an existing branch is never changed.
  if git show-ref --verify --quiet "refs/remotes/midstream/${target}"; then
    echo "Skipping existing ${target}"
    continue
  fi
  upstream_ref="refs/remotes/upstream/${y_branch}"
  git fetch --no-tags upstream "+refs/tags/${tag}:refs/tags/${tag}" "+refs/heads/${y_branch}:${upstream_ref}"
  tag_commit=$(git rev-parse "refs/tags/${tag}^{commit}")

  # Security releases are tagged on a side branch whose commits are cherry-picked
  # back to the y-stream branch with new SHAs, so the newest commit the tag shares
  # with the y-stream branch is where that side branch was cut. For releases tagged
  # on the y-stream branch itself, this is the tagged commit.
  branch_point=$(git merge-base "${tag_commit}" "${upstream_ref}")
  # Midstream patches are reconciled with upstream once, by the y-stream sync.
  # Wait for it to reach the branch point instead of repeating that work here.
  if ! is_ancestor "${branch_point}" "${midstream_ref}"; then
    echo "Waiting for ${y_branch} to sync upstream ${branch_point} before creating ${target}"
    continue
  fi
  # Upstream release branches are linear, so a midstream commit containing any
  # upstream change made after the branch point also contains the first one.
  first_after=$(git rev-list --reverse --first-parent "${upstream_ref}" "^${branch_point}" | sed -n 1p)
  cut_point=$(find_cut_point "${midstream_ref}" "${first_after}")

  commit=${cut_point}
  # The cut point can lack upstream commits up to the branch point, when one sync
  # merged them together with later changes, and always lacks a security release's
  # own commits. Merge the tag to bring them in before the branch exists.
  if ! is_ancestor "${tag_commit}" "${cut_point}"; then
    if [[ -z ${bot_login} ]]; then
      bot_login=$(gh api user --jq .login)
      git config --global user.name "${bot_login}"
      git config --global user.email "${bot_login}@users.noreply.github.com"
    fi
    commit=$(merge_tag "${target}" "${tag}" "${cut_point}" "${branch_point}" "${upstream_ref}") || {
      failed=1
      continue
    }
  fi

  # The empty lease rejects the push if the branch was created since the fetch.
  git push --quiet --force-with-lease="refs/heads/${target}:" midstream "${commit}:refs/heads/${target}"
  if [[ ${commit} == "${cut_point}" ]]; then
    echo "Created ${target} at ${cut_point}, the last ${y_branch} commit before upstream ${first_after:-<none>}"
  else
    echo "Created ${target} at ${commit}, merging upstream tag ${tag} into ${cut_point}"
  fi
done
exit "${failed}"
