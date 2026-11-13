#!/bin/bash
set +x
set -euo pipefail

# Never place the token in a remote URL or in traced command arguments.
export GH_TOKEN
GH_TOKEN=$(< /creds-github/token)
repo=openshift-service-mesh/istio

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT
# This job checks out istio, not openshift/release; read policy from its default branch.
gh api repos/openshift/release/contents/ci-operator/config/openshift-service-mesh/supported-istio-versions.txt \
  -H 'Accept: application/vnd.github.raw+json' > "${workdir}/supported-istio-versions.txt"
mapfile -t supported_versions < "${workdir}/supported-istio-versions.txt"

# Requires --merge-tag support in maistra/test-infra's automator.
git clone --quiet --single-branch --depth=1 --branch main https://github.com/maistra/test-infra.git "${workdir}/test-infra"

# Handle istio.deps like the y-stream sync jobs: take upstream's file during the
# merge, then the post-merge hook restores the downstream proxy/ztunnel pins.
export GIT_CONFIG_GLOBAL="${workdir}/gitconfig"
echo 'istio.deps merge=istio-deps' > "${workdir}/gitattributes"
git config --global core.attributesFile "${workdir}/gitattributes"
git config --global merge.istio-deps.name 'take upstream istio.deps'
git config --global merge.istio-deps.driver 'cp %B %A'
cat > "${workdir}/post-merge.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# Never publish a z-stream branch containing upstream changes made after its branch point.
upstream_ref="refs/remotes/upstream/${ZSTREAM_UPSTREAM_BRANCH}"
git fetch --quiet --no-tags upstream "+refs/heads/${ZSTREAM_UPSTREAM_BRANCH}:${upstream_ref}"
merge_base=$(git merge-base HEAD "${upstream_ref}")
if [[ ${merge_base} != "${ZSTREAM_BRANCH_POINT}" ]]; then
  echo "Expected the merge to share ${ZSTREAM_BRANCH_POINT} with ${upstream_ref}, got ${merge_base}" >&2
  exit 1
fi

downstream=$(git rev-parse "origin/${AUTOMATOR_BRANCH}")
if [[ $(git rev-parse HEAD^1) != "${downstream}" ]]; then
  echo 'Expected a new merge commit with the downstream branch as its first parent' >&2
  exit 1
fi
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
git show "${downstream}:istio.deps" > "${tmp}/downstream"
git show "HEAD^2:istio.deps" > "${tmp}/upstream"
jq -e --slurpfile downstream "${tmp}/downstream" '
  reduce ["PROXY_REPO_SHA", "ZTUNNEL_REPO_SHA"][] as $name (. ;
    ($downstream[0] | map(select(.name == $name))) as $pin
    | if ($pin | length) != 1
        or ($pin[0].lastStableSHA | type) != "string"
        or ($pin[0].lastStableSHA | length) == 0
        or (map(select(.name == $name)) | length) != 1
      then error("Missing, duplicate, or invalid pin: " + $name)
      else map(if .name == $name then .lastStableSHA = $pin[0].lastStableSHA else . end)
      end)
' "${tmp}/upstream" > "${tmp}/merged"
cp "${tmp}/merged" istio.deps
git add istio.deps
if ! git diff --cached --quiet -- istio.deps; then
  git -c "user.name=$(git show -s --format=%cn HEAD)" \
      -c "user.email=$(git show -s --format=%ce HEAD)" commit --amend --no-edit
fi
EOF

cd "${workdir}"
git init --quiet --bare repo.git
cd repo.git
git remote add midstream https://github.com/openshift-service-mesh/istio.git
git remote add upstream https://github.com/istio/istio.git
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

# merge_tag opens a PR merging the upstream tag into the z-stream branch. Conflicts
# are never resolved here: the automator reports them in a draft PR instead.
merge_tag() {
  local target=$1 tag=$2 branch_point=$3 y_branch=$4
  (
    cd "${workdir}/test-infra"
    ZSTREAM_BRANCH_POINT=${branch_point} ZSTREAM_UPSTREAM_BRANCH=${y_branch} ./tools/automator-main.sh \
      --org=openshift-service-mesh \
      --repo=istio \
      --branch="${target}" \
      --token-path=/creds-github/token \
      "--title=Automator: merge upstream tag ${tag} into \$AUTOMATOR_ORG/\$AUTOMATOR_REPO@\$AUTOMATOR_BRANCH" \
      --labels=tide/merge-method-merge,auto-merge \
      --modifier="merge_upstream_istio_${tag}" \
      --merge-repository=https://github.com/istio/istio \
      --merge-tag="${tag}" \
      --merge-failure-pr \
      --post-merge-hook="${workdir}/post-merge.sh"
  )
}

failed=0
for release_line in "${supported_versions[@]}"; do
  y_branch="release-${release_line}"
  midstream_ref="refs/remotes/midstream/${y_branch}"
  git show-ref --verify --quiet "${midstream_ref}" || continue
  # List tag names without fetching their histories; exclude prereleases and patch zero.
  tag=$(git ls-remote --tags --refs upstream "refs/tags/${release_line}.*" |
    awk -F/ '$3 ~ /^[0-9]+\.[0-9]+\.[1-9][0-9]*$/ {print $3}' |
    sort -V | tail -n 1)
  [[ -n ${tag} ]] || continue
  target="release-${tag}"
  target_ref="refs/remotes/midstream/${target}"
  upstream_ref="refs/remotes/upstream/${y_branch}"
  git fetch --no-tags upstream "+refs/tags/${tag}:refs/tags/${tag}" "+refs/heads/${y_branch}:${upstream_ref}"
  tag_commit=$(git rev-parse "refs/tags/${tag}^{commit}")
  # Security releases are tagged on a side branch whose commits are cherry-picked
  # back to the y-stream branch with new SHAs, so the newest commit the tag shares
  # with the y-stream branch is where that side branch was cut. For releases tagged
  # on the y-stream branch itself, this is the tagged commit.
  branch_point=$(git merge-base "${tag_commit}" "${upstream_ref}")

  if git show-ref --verify --quiet "${target_ref}"; then
    if is_ancestor "${tag_commit}" "${target_ref}"; then
      echo "Skipping existing ${target}: it already contains ${tag}"
      continue
    fi
    # An earlier run created the branch, but merging the tag is still pending.
    echo "${target} exists but does not contain ${tag} yet; merging the tag"
  else
    # Midstream patches are reconciled with upstream once, by the y-stream sync.
    # Wait for it to reach the branch point instead of repeating that work here.
    if ! is_ancestor "${branch_point}" "${midstream_ref}"; then
      echo "Waiting for ${y_branch} to sync upstream ${branch_point} before creating ${target}"
      continue
    fi
    # Istio's release branches are linear, so a midstream commit containing any
    # upstream change made after the branch point also contains the first one.
    first_after=$(git rev-list --reverse --first-parent "${upstream_ref}" "^${branch_point}" | sed -n 1p)
    cut_point=$(find_cut_point "${midstream_ref}" "${first_after}")
    gh api --method POST "repos/${repo}/git/refs" \
      -f ref="refs/heads/${target}" -f sha="${cut_point}" >/dev/null
    echo "Created ${target} at ${cut_point}, the last ${y_branch} commit before upstream ${first_after:-<none>}"
    if is_ancestor "${tag_commit}" "${cut_point}"; then
      continue
    fi
  fi

  # The cut point can lack upstream commits up to the branch point, when one sync
  # merged them together with later changes, and always lacks a security release's
  # own commits. Merge the tag to bring them in.
  merge_tag "${target}" "${tag}" "${branch_point}" "${y_branch}" || failed=1
done
exit "${failed}"
