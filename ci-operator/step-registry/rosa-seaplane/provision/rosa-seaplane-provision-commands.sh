#!/bin/bash

set -euo pipefail

WORK_DIR="$(mktemp -d)"

# Resolve which rosa-seaplane repo + branch to provision from. The ephemeral
# provider deploys REPOSITORY_URL/REPOSITORY_BRANCH from GitHub, so on a
# rosa-seaplane PR this is the PR's head branch (on its fork, if any); for
# any other job it is ROSA_REGIONAL_PLATFORM_REF of openshift-online/rosa-seaplane.
if [[ "${REPO_NAME:-}" == "rosa-seaplane" ]] && [[ -n "${PULL_NUMBER:-}" ]]; then
  REPOSITORY_URL="$(curl -sSf --retry 5 \
    "https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PULL_NUMBER}" \
    | jq -r '.head.repo.clone_url')"
  REPOSITORY_BRANCH="${PULL_HEAD_REF}"
else
  REPOSITORY_URL="https://github.com/openshift-online/rosa-seaplane.git"
  REPOSITORY_BRANCH="${ROSA_REGIONAL_PLATFORM_REF}"
fi
export REPOSITORY_URL REPOSITORY_BRANCH

echo "Cloning ${REPOSITORY_URL} at ref ${REPOSITORY_BRANCH}..."
git clone --depth 1 --branch "${REPOSITORY_BRANCH}" "${REPOSITORY_URL}" "${WORK_DIR}/platform"
cd "${WORK_DIR}/platform"

# Pin the source and exact commit SHA so e2e and teardown use the same code
PINNED_SHA="$(git rev-parse HEAD)"
if [[ -n "${PULL_PULL_SHA:-}" ]] && [[ "${REPO_NAME:-}" == "rosa-seaplane" ]] && [[ "${PINNED_SHA}" != "${PULL_PULL_SHA}" ]]; then
  echo "ERROR: ${REPOSITORY_BRANCH} moved to ${PINNED_SHA} after this job started at ${PULL_PULL_SHA}; /retest" >&2
  exit 1
fi
declare -p REPOSITORY_URL REPOSITORY_BRANCH PINNED_SHA > "${SHARED_DIR}/rosa-seaplane-source.env"
echo "Pinned ${REPOSITORY_URL}@${REPOSITORY_BRANCH} at ${PINNED_SHA}"

# Write one override file per ROSA_REGIONAL_COMPONENTS entry that has a
# target, with IMAGE_REPO/IMAGE_TAG replaced by the image-push result and
# PR_SOURCE_SHA replaced by the triggering PR's source commit.
# Prints one "<target>:<override-file>" line per override.
write_overrides() {
  python3 <<'PYEOF'
import os, re, sys, yaml
shared = os.environ["SHARED_DIR"]
pushed = {}
pushed_file = os.path.join(shared, "component-images")
if os.path.exists(pushed_file):
    with open(pushed_file) as f:
        for line in f:
            repo, _, tag = line.strip().rpartition(":")
            pushed[repo] = tag
source_revision = os.environ.get("PULL_PULL_SHA", "")
components = yaml.safe_load(os.environ["ROSA_REGIONAL_COMPONENTS"]) or []
for i, c in enumerate(components):
    repo = c.get("repo", "")
    if c.get("image") and repo not in pushed:
        sys.exit(f"ERROR: no image was pushed for {c['image']} -> {repo or '(no repo)'}; see the image-push step")
    if "target" not in c or "override" not in c:
        continue
    text = yaml.safe_dump(c["override"], default_flow_style=False)
    if repo:
        text = text.replace("IMAGE_REPO", repo)
    if repo in pushed:
        text = text.replace("IMAGE_TAG", pushed[repo])
    if "PR_SOURCE_SHA" in text:
        if not re.fullmatch(r"[0-9a-fA-F]{40}", source_revision):
            sys.exit("ERROR: PR_SOURCE_SHA requires PULL_PULL_SHA to contain a full 40-character commit SHA")
        text = text.replace("PR_SOURCE_SHA", source_revision)
    path = os.path.join(shared, f"component-override-{i}.yaml")
    with open(path, "w") as f:
        f.write(text)
    print(f"{c['target']}:{path}")
PYEOF
}

OVERRIDE_ARGS=()
if [[ -n "${ROSA_REGIONAL_COMPONENTS:-}" ]]; then
  OVERRIDE_LIST="$(write_overrides)"
  mapfile -t OVERRIDES <<< "${OVERRIDE_LIST}"
  for override in "${OVERRIDES[@]}"; do
    [[ -n "${override}" ]] || continue
    echo "Override for ${override%%:*}:"
    cat "${override#*:}"
    OVERRIDE_ARGS+=(--provision-override-file "${override}")
  done
fi

echo "Starting ephemeral provisioning..."
uv run --no-cache ci/ephemeral-provider/main.py \
  --save-regional-state "${SHARED_DIR}/regional-terraform-outputs.json" \
  --save-management-state "${SHARED_DIR}/management-terraform-outputs.json" \
  "${OVERRIDE_ARGS[@]}"
