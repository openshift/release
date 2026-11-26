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
# target, with IMAGE_REPO/IMAGE_TAG replaced by the image-push result.
# PR_SOURCE_SHA is the rosa-seaplane-api commit from JOB_SPEC (refs or
# extra_refs), the same bag resolve-ocp-image already uses. That is the
# checkout the images were built from. PULL_PULL_SHA is not used: on
# pj-rehearse it is the openshift/release commit. If JOB_SPEC has no
# api SHA, the key is dropped. Prints one "<target>:<override-file>"
# line per override.
write_overrides() {
  python3 <<'PYEOF'
import copy, json, os, re, sys, yaml

CHART_SOURCE_ORG = "openshift-online"
CHART_SOURCE_REPO = "rosa-seaplane-api"

shared = os.environ["SHARED_DIR"]
pushed = {}
pushed_file = os.path.join(shared, "component-images")
if os.path.exists(pushed_file):
    with open(pushed_file) as f:
        for line in f:
            repo, _, tag = line.strip().rpartition(":")
            pushed[repo] = tag


def drop_pr_source_sha(obj):
    # Leave no literal PR_SOURCE_SHA for Argo CD to treat as a git revision.
    if isinstance(obj, dict):
        out = {}
        for key, value in obj.items():
            if key == "targetRevision" and value == "PR_SOURCE_SHA":
                continue
            out[key] = drop_pr_source_sha(value)
        return out
    if isinstance(obj, list):
        return [drop_pr_source_sha(v) for v in obj]
    return obj


def ref_sha(r):
    pulls = r.get("pulls") or []
    return (pulls[0].get("sha") if pulls else None) or r.get("base_sha") or ""


def api_pr_source_sha():
    # Chart SHA is the rosa-seaplane-api git commit in JOB_SPEC, not
    # PULL_PULL_SHA. On an api presubmit that is refs; on pj-rehearse
    # refs is openshift/release and the api checkout is extra_refs
    # (workdir:true), same as resolve-ocp-image. pulls[0].sha if the
    # extra_ref is a PR, else base_sha. No api ref → drop the pin.
    spec = {}
    raw = os.environ.get("JOB_SPEC") or ""
    if raw:
        try:
            spec = json.loads(raw)
        except json.JSONDecodeError:
            spec = {}
    candidates = [r for r in [spec.get("refs"), *(spec.get("extra_refs") or [])] if r]
    api_refs = [
        r for r in candidates
        if r.get("org") == CHART_SOURCE_ORG and r.get("repo") == CHART_SOURCE_REPO
    ]
    ordered = [r for r in api_refs if r.get("workdir") is True] + [
        r for r in api_refs if r.get("workdir") is not True
    ]
    for r in ordered:
        sha = ref_sha(r)
        if re.fullmatch(r"[0-9a-fA-F]{40}", sha or ""):
            return sha
    return ""


source_revision = api_pr_source_sha()
components = yaml.safe_load(os.environ["ROSA_REGIONAL_COMPONENTS"]) or []
for i, c in enumerate(components):
    repo = c.get("repo", "")
    if c.get("image") and repo not in pushed:
        sys.exit(f"ERROR: no image was pushed for {c['image']} -> {repo or '(no repo)'}; see the image-push step")
    if "target" not in c or "override" not in c:
        continue
    override = copy.deepcopy(c["override"])
    if not source_revision:
        override = drop_pr_source_sha(override)
    text = yaml.safe_dump(override, default_flow_style=False)
    if repo:
        text = text.replace("IMAGE_REPO", repo)
    if repo in pushed:
        text = text.replace("IMAGE_TAG", pushed[repo])
    if source_revision and "PR_SOURCE_SHA" in text:
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
