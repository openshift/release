#!/usr/bin/env bash
set -euo pipefail

repo=openshift-online/rosa-boundary
base=main
branch=openwiki/update
app_id_file=/var/run/rosa-boundary-github-app-id/github-app-app-id
installation_id_file=/var/run/rosa-boundary-github-app-installation/github-app-installation-id
private_key_file=/var/run/rosa-boundary-github-app-key/github-app-pem
if [[ ! -s "$GOOGLE_APPLICATION_CREDENTIALS" ]]; then
  echo 'Missing rosa-boundary/ci/gcp-vertex-sa-key credential.' >&2
  exit 1
fi
for file in "$app_id_file" "$installation_id_file" "$private_key_file"; do
  if [[ ! -s "$file" ]]; then
    echo "Missing required GitHub App credential at ${file}" >&2
    exit 1
  fi
done

# Fail closed if this step is handed another project's or initiative's key.
# Do not infer the account ID from the repo name: this account already exists.
GOOGLE_CLOUD_PROJECT=$(jq -er 'select(.type == "service_account") | .project_id' "$GOOGLE_APPLICATION_CREDENTIALS")
client_email=$(jq -er '.client_email' "$GOOGLE_APPLICATION_CREDENTIALS")
if [[ -z "${ROSA_BOUNDARY_VERTEX_PROJECT_ID:-}" || "$GOOGLE_CLOUD_PROJECT" != "$ROSA_BOUNDARY_VERTEX_PROJECT_ID" ]]; then
  echo 'Vertex key project does not match the configured ROSA Boundary project ID.' >&2
  exit 1
fi
if [[ -z "${ROSA_BOUNDARY_VERTEX_SERVICE_ACCOUNT_EMAIL:-}" || "$client_email" != "$ROSA_BOUNDARY_VERTEX_SERVICE_ACCOUNT_EMAIL" ]]; then
  echo 'Vertex key account does not match the configured ROSA Boundary service account.' >&2
  exit 1
fi
export GOOGLE_CLOUD_PROJECT

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Install tools into this periodic's writable workspace, not into the image or
# on every PR. OpenWiki 0.7.1 requires Node >=22.22.0. Verify the archive for
# either build-farm architecture before unpacking it.
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

# Keep the GitHub App token out of remote URLs, process arguments, and logs.
# Generate it again after the model run because installation tokens expire.
github_token() {
  local now header payload signature jwt
  now=$(date +%s)
  header=$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  payload=$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' \
    "$((now - 60))" "$((now + 540))" "$(cat "$app_id_file")" \
    | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  signature=$(printf '%s' "${header}.${payload}" \
    | openssl dgst -sha256 -sign "$private_key_file" \
    | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  jwt="${header}.${payload}.${signature}"
  curl -fsS -X POST -H "Authorization: Bearer ${jwt}" \
    -H 'Accept: application/vnd.github+json' \
    -H 'Content-Type: application/json' \
    --data '{"repositories":["rosa-boundary"],"permissions":{"contents":"write","pull_requests":"write"}}' \
    "https://api.github.com/app/installations/$(cat "$installation_id_file")/access_tokens" \
    | jq -er '.token'
}

cat > "${workdir}/askpass" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  *Username*) printf '%s\n' x-access-token ;;
  *Password*) printf '%s\n' "$GITHUB_TOKEN" ;;
esac
EOF
chmod 700 "${workdir}/askpass"
export GIT_ASKPASS="${workdir}/askpass" GIT_TERMINAL_PROMPT=0
export GITHUB_TOKEN
GITHUB_TOKEN=$(github_token)

# Prow's source checkout may be shallow. OpenWiki requires the full history to
# diff against its last documented commit, and an existing PR needs its own
# branch as the baseline so unfinished pages survive the next run.
git clone "https://github.com/${repo}.git" "${workdir}/repo"
cd "${workdir}/repo"
git config user.name 'OpenShift CI Bot'
git config user.email 'ci-bot@redhat.com'

existing_pr=$(gh pr list --repo "$repo" --base "$base" --head "$branch" \
  --state open --json number --jq '.[0].number // empty')
if [[ -n "$existing_pr" ]]; then
  git fetch origin "$branch"
  git switch -c "$branch" "origin/${branch}"
  # Do not silently rewrite a docs PR when main has diverged from it.
  git merge --no-edit "origin/${base}"
else
  if git ls-remote --exit-code origin "refs/heads/${branch}" >/dev/null; then
    echo "${branch} exists without an open PR; inspect/remove the stale bot branch before rerunning." >&2
    exit 1
  fi
  git switch -c "$branch" "origin/${base}"
fi

# Do not expose a GitHub write token to the OpenWiki agent. Its Google ADC
# credential remains mounted for model inference through the Vertex SDK.
unset GITHUB_TOKEN GIT_ASKPASS
export LANGCHAIN_TRACING_V2=false
set +e
openwiki code --update --print
update_status=$?
set -e

# The generated GitHub Action is intentionally not published by this Prow job.
# Keep run state out of the PR, but retain completed pages after a failed run.
rm -f openwiki/.run.json
for path in openwiki AGENTS.md CLAUDE.md; do
  if [[ -e "$path" || -n "$(git ls-files -- "$path")" ]]; then
    git add -A -- "$path"
  fi
done
if git diff --cached --quiet; then
  echo 'No OpenWiki documentation changes to publish.'
  exit "$update_status"
fi

git commit -m 'docs: update OpenWiki'
GITHUB_TOKEN=$(github_token)
export GITHUB_TOKEN GIT_ASKPASS="${workdir}/askpass"
git push origin "HEAD:refs/heads/${branch}"

if [[ -n "$existing_pr" ]]; then
  pr_url="https://github.com/${repo}/pull/${existing_pr}"
else
  pr_body=$(printf 'Automated OpenWiki documentation update from Prow.\n\nOpenWiki exit status: %s. Failed runs may include completed pages; review before merging.\n' "$update_status")
  pr_url=$(gh pr create --repo "$repo" --base "$base" --head "$branch" \
    --title 'docs: update OpenWiki' \
    --body "$pr_body")
fi
echo "OpenWiki PR: ${pr_url}"
exit "$update_status"
