#!/usr/bin/env bash
set -euo pipefail

if [[ ! -s "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
  echo 'Missing rosa-boundary/ci/gcp-vertex-sa-key credential.' >&2
  exit 1
fi

# Fail closed if this step is handed another project's or initiative's key.
GOOGLE_CLOUD_PROJECT=$(jq -er 'select(.type == "service_account") | .project_id' "$GOOGLE_APPLICATION_CREDENTIALS")
client_email=$(jq -er '.client_email' "$GOOGLE_APPLICATION_CREDENTIALS")
if [[ "$GOOGLE_CLOUD_PROJECT" != "$ROSA_BOUNDARY_VERTEX_PROJECT_ID" || "$client_email" != "$ROSA_BOUNDARY_VERTEX_SERVICE_ACCOUNT_EMAIL" ]]; then
  echo 'Vertex key does not belong to the configured ROSA Boundary service account.' >&2
  exit 1
fi
export GOOGLE_CLOUD_PROJECT

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

# Only flat files survive between steps in SHARED_DIR. Clone the public repo
# locally so the model container never receives GitHub App credentials.
base_branch=$(cat "${SHARED_DIR}/openwiki-base-branch")
case "$base_branch" in
  main|openwiki/update) ;;
  *) echo 'Unexpected OpenWiki base branch.' >&2; exit 1 ;;
esac
git clone https://github.com/openshift-online/rosa-boundary.git "$workdir/repo"
cd "$workdir/repo"
git config user.name 'OpenShift CI Bot'
git config user.email 'ci-bot@redhat.com'
git switch -c openwiki/update "origin/${base_branch}"
if [[ "$base_branch" != main ]]; then
  git merge --no-edit origin/main
fi
export LANGCHAIN_TRACING_V2=false
set +e
openwiki code --update --print
update_status=$?
set -e
printf '%s\n' "$update_status" > "${SHARED_DIR}/openwiki-exit-status"

# Transfer only the generated documentation, never the agent's git directory
# or worktree, to a separate publisher without Vertex/model credentials.
rm -f openwiki/.run.json
for path in openwiki AGENTS.md CLAUDE.md; do
  if [[ -e "$path" || -n "$(git ls-files -- "$path")" ]]; then
    git add -A -- "$path"
  fi
done
git diff --cached --binary > "${SHARED_DIR}/openwiki-docs.patch"
echo "OpenWiki exited with status ${update_status}; publish step will handle any completed pages."
