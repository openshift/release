#!/bin/bash
set +x
set -euo pipefail

# Never place the token in a remote URL or in traced command arguments.
export GH_TOKEN
GH_TOKEN=$(< /creds-github/token)
repo=openshift-service-mesh/istio

workdir=$(mktemp -d)
trap 'rm -rf "${workdir}"' EXIT
cd "${workdir}"
git init --bare repo.git
cd repo.git
git remote add midstream https://github.com/openshift-service-mesh/istio.git
git remote add upstream https://github.com/istio/istio.git
# Fetch complete histories: shallow clones cannot establish ancestry reliably.
git fetch --no-tags midstream '+refs/heads/release-*:refs/remotes/midstream/release-*'

# Read all open issues once, including pagination, to avoid daily duplicates.
issues=$(gh api --paginate --slurp "repos/${repo}/issues?state=open&per_page=100" | jq 'add')

failed=0
# Only these y-stream lines are supported, regardless of other midstream branches.
for release_line in 1.30 1.31; do
  source="refs/remotes/midstream/release-${release_line}"
  git show-ref --verify --quiet "${source}" || continue
  # List tag names without fetching their histories; exclude prereleases and patch zero.
  tag=$(git ls-remote --tags --refs upstream "refs/tags/${release_line}.*" |
    awk -F/ '$3 ~ /^[0-9]+\.[0-9]+\.[1-9][0-9]*$/ {print $3}' |
    sort -V | tail -n 1)
  [[ -n ${tag} ]] || continue
  target="release-${tag}"
  if git show-ref --verify --quiet "refs/remotes/midstream/${target}"; then
    echo "Skipping existing ${target}"
    continue
  fi
  # Fetch only the selected tag, and only when its z-stream branch is missing.
  git fetch --no-tags upstream "refs/tags/${tag}:refs/tags/${tag}"
  source_commit=$(git rev-parse "${source}^{commit}")
  tag_commit=$(git rev-parse "refs/tags/${tag}^{commit}")
  if git merge-base --is-ancestor "${tag_commit}" "${source_commit}"; then
    # Branch at the tagged commit, excluding any later y-stream commits.
    gh api --method POST "repos/${repo}/git/refs" \
      -f ref="refs/heads/${target}" -f sha="${tag_commit}" >/dev/null
    echo "Created ${target} at tag ${tag} commit ${tag_commit}, verified in ${source#refs/remotes/midstream/}"
    continue
  else
    status=$?
    [[ ${status} -eq 1 ]] || exit "${status}"
  fi

  failed=1
  title="Cannot create ${target}: upstream tag is missing from ${source#refs/remotes/midstream/}"
  echo "ERROR: ${title} (${tag_commit})" >&2
  if jq -e --arg title "${title}" 'any(.[]; .title == $title and (has("pull_request") | not))' <<< "${issues}" >/dev/null; then
    echo 'An open issue already reports this missing commit.'
    continue
  fi
  body="Upstream istio/istio tag ${tag} points to ${tag_commit}, which is not an ancestor of openshift-service-mesh/istio ${source#refs/remotes/midstream/} (${source_commit}).

The daily OSSM release-branch job did not create ${target}. Sync the y-stream branch with upstream; the next daily run will retry."
  gh issue create --repo "${repo}" --title "${title}" --body "${body}"
done
exit "${failed}"
