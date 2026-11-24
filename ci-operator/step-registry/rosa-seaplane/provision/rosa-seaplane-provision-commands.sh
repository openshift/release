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
# PR_SOURCE_SHA replaced by the rosa-seaplane-api commit from JOB_SPEC.
# Prints one "<target>:<override-file>" line per override.
write_overrides() {
  python3 <<'PYEOF'
import json, os, re, sys, yaml

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


def chart_source_sha():
    # PULL_PULL_SHA is the triggering PR head. On an api presubmit that is
    # the chart commit we want. On pj-rehearse of openshift/release it is
    # the release commit, which is not in rosa-seaplane-api and makes Argo
    # CD 422. Resolve from JOB_SPEC the same way clonerefs does: the
    # openshift-online/rosa-seaplane-api ref (pull SHA, else base_sha).
    #
    # Rehearsals set REPO_NAME to "release", so the PULL_PULL_SHA fallback
    # below does not run. JOB_SPEC.extra_refs must include this repo with
    # pulls[0].sha or base_sha; otherwise this returns empty and provision
    # exits before creating the environment.
    spec = {}
    raw = os.environ.get("JOB_SPEC") or ""
    if raw:
        try:
            spec = json.loads(raw)
        except json.JSONDecodeError:
            spec = {}
    refs = [r for r in [spec.get("refs"), *(spec.get("extra_refs") or [])] if r]
    for r in refs:
        if r.get("org") != CHART_SOURCE_ORG or r.get("repo") != CHART_SOURCE_REPO:
            continue
        pulls = r.get("pulls") or []
        sha = (pulls[0].get("sha") if pulls else None) or r.get("base_sha") or ""
        if sha:
            return sha
    if (
        os.environ.get("REPO_OWNER") == CHART_SOURCE_ORG
        and os.environ.get("REPO_NAME") == CHART_SOURCE_REPO
    ):
        return os.environ.get("PULL_PULL_SHA") or ""
    return ""


CHART_SOURCE_SHA_ERROR = (
    "ERROR: PR_SOURCE_SHA needs a 40-character commit SHA of "
    f"{CHART_SOURCE_ORG}/{CHART_SOURCE_REPO} in JOB_SPEC. Expected "
    "refs or extra_refs[] with org="
    f"{CHART_SOURCE_ORG} repo={CHART_SOURCE_REPO} and pulls[0].sha "
    "(api presubmit) or base_sha (openshift/release rehearsal extra_ref)."
)


source_revision = chart_source_sha()
components = yaml.safe_load(os.environ["ROSA_REGIONAL_COMPONENTS"]) or []
needs_chart_sha = any(
    "PR_SOURCE_SHA" in yaml.safe_dump(c.get("override") or {}, default_flow_style=False)
    for c in components
    if "target" in c and "override" in c
)
if needs_chart_sha and not re.fullmatch(r"[0-9a-fA-F]{40}", source_revision):
    sys.exit(f"{CHART_SOURCE_SHA_ERROR} (got {source_revision!r})")
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
