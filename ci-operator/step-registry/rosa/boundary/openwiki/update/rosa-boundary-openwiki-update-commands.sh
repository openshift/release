#!/usr/bin/env bash
set -euo pipefail

repo=${TARGET_REPO:?}
base=${TARGET_BASE_BRANCH:?}
branch=${TARGET_UPDATE_BRANCH:?}
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo 'Invalid OpenWiki repository.' >&2; exit 1; }
git check-ref-format --branch "$base" >/dev/null
git check-ref-format --branch "$branch" >/dev/null

if [[ ! -s "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
  echo 'Missing rosa-boundary/ci/gcp-vertex-sa-key credential.' >&2
  exit 1
fi

# Fail closed if this step is handed another project's or initiative's key.
GOOGLE_CLOUD_PROJECT=$(jq -er 'select(.type == "service_account") | .project_id' "$GOOGLE_APPLICATION_CREDENTIALS")
client_email=$(jq -er '.client_email' "$GOOGLE_APPLICATION_CREDENTIALS")
if [[ "$GOOGLE_CLOUD_PROJECT" != "$TARGET_VERTEX_PROJECT_ID" || "$client_email" != "$TARGET_VERTEX_SERVICE_ACCOUNT_EMAIL" ]]; then
  echo 'Vertex key does not belong to the configured ROSA Boundary service account.' >&2
  exit 1
fi
export GOOGLE_CLOUD_PROJECT
# The periodic config uses TARGET_* names; OpenWiki itself reads OPENWIKI_*.
export OPENWIKI_PROVIDER=${TARGET_PROVIDER:?}
export OPENWIKI_MODEL_ID=${TARGET_MODEL_ID:?}

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Install tools only during this periodic. OpenWiki 0.7.1 needs Node >=22.22.0.
case "$(uname -m)" in
  x86_64) node_arch=x64; node_sha=9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37 ;;
  aarch64) node_arch=arm64; node_sha=1bf1eb9ee63ffc4e5d324c0b9b62cf4a289f44332dfef9607cea1a0d9596ba6f ;;
  *) echo 'Unsupported architecture for Node 22' >&2; exit 1 ;;
esac
curl -fsSL "https://nodejs.org/dist/v22.22.0/node-v22.22.0-linux-${node_arch}.tar.xz" -o "$workdir/node.tar.xz"
printf '%s  %s\n' "$node_sha" "$workdir/node.tar.xz" | sha256sum -c -
mkdir -p "$workdir/node"
tar -xJf "$workdir/node.tar.xz" --strip-components=1 -C "$workdir/node"
rm "$workdir/node.tar.xz"
export PATH="$workdir/node/bin:$workdir/tools/bin:$PATH"
npm install --global --prefix "$workdir/tools" openwiki@0.7.1 mermaid@11.16.0 jsdom@29.1.1
# Record the installed version and requested model for the publisher's PR
# description. SHARED_DIR accepts only flat files; no credentials cross steps.
jq -er '.version' "$workdir/tools/lib/node_modules/openwiki/package.json" > "${SHARED_DIR}/openwiki-version"
printf '%s\n' "$OPENWIKI_MODEL_ID" > "${SHARED_DIR}/openwiki-model-id"
printf '%s\n' "$OPENWIKI_PROVIDER" > "${SHARED_DIR}/openwiki-provider"

# Only flat files survive between steps in SHARED_DIR. Clone the public repo
# locally so the model container never receives GitHub App credentials.
base_branch=$(cat "${SHARED_DIR}/openwiki-base-branch")
if [[ "$base_branch" != "$base" && "$base_branch" != "$branch" ]]; then
  echo 'Unexpected OpenWiki base branch.' >&2
  exit 1
fi
git clone "https://github.com/${repo}.git" "$workdir/repo"
cd "$workdir/repo"
git config user.name 'OpenShift CI Bot'
git config user.email 'ci-bot@redhat.com'
git switch -c "$branch" "origin/${base_branch}"
if [[ "$base_branch" != "$base" ]]; then
  git merge --no-edit "origin/${base}"
fi
export LANGCHAIN_TRACING_V2=false
set +e
openwiki code --update --print
update_status=$?
set -e
printf '%s\n' "$update_status" > "${SHARED_DIR}/openwiki-exit-status"

# Transfer only the generated wiki, never the agent's git directory, worktree,
# or OpenWiki's hard-coded AGENTS.md / CLAUDE.md setup changes. Those root
# guidance files are owned by the repository, not this scheduled update.
rm -f openwiki/.run.json
if [[ -e openwiki || -n "$(git ls-files -- openwiki)" ]]; then
  git add -A -- openwiki
fi
git diff --cached --binary -- openwiki/ > "${SHARED_DIR}/openwiki-docs.patch"
echo "OpenWiki exited with status ${update_status}; publish step will handle any completed pages."
