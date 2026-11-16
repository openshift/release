#!/bin/bash
# Run offline runner tests with the same image used by the eval step.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
engine="${CONTAINER_ENGINE:-podman}"
image="${EVAL_TEST_IMAGE:-registry.ci.openshift.org/ci/claude-ai-helpers:latest}"

# Override EVAL_TEST_IMAGE with an image digest to reproduce a particular CI run.
"${engine}" run --rm --interactive --network=none --platform linux/amd64 \
    --volume "${repo_root}:/release:ro" --workdir /release \
    --env PYTHONDONTWRITEBYTECODE=1 --entrypoint /bin/bash "${image}" -s <<'CONTAINER'
set -euo pipefail
python3 hack/claude-agent-eval/sync_commands.py --check
python3 -m unittest discover -s hack/claude-agent-eval -p "test_*.py" -v

# Run the distributed entry point as Prow does: a checkout with no .git (no
# Git history), changed files from JOB_SPEC, and the GitHub API faked by the
# test-only sitecustomize on PYTHONPATH. The network stays disabled.
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
python3 - "${work}" <<'PYTHON'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
(work / "repo/evals").mkdir(parents=True)
(work / "repo/evals.yaml").write_text(json.dumps({"evals": [{
    "config": "evals/eval-foo.yaml", "run": "pr", "parallelism": 1, "max_turns": 1, "triggers": ["skills/foo/"]}]}))
(work / "repo/evals/eval-foo.yaml").write_text("name: example\n")
(work / "job-spec.json").write_text(json.dumps({"type": "presubmit", "refs": {
    "org": "openshift-eng", "repo": "example", "base_ref": "main", "pulls": [{"number": 7, "sha": "a" * 40}]}}))
for name, head in (("tested", "a" * 40), ("moved", "b" * 40)):
    (work / f"{name}.json").write_text(json.dumps({"pulls": {"openshift-eng/example#7": {
        "head_sha": head, "files": [{"filename": "docs/guide.md", "status": "modified"}]}}}))
PYTHON
run_entry_point() {
    env EVAL_WORKDIR="${work}/repo" ARTIFACT_DIR="${work}/artifacts-$1" JOB_TYPE=presubmit \
        JOB_SPEC="$(cat "${work}/job-spec.json")" EVAL_TEST_GITHUB_FIXTURE="${work}/$1.json" \
        PYTHONPATH=/release/hack/claude-agent-eval/testing \
        bash ci-operator/step-registry/openshift/claude/agent-eval/manifest/openshift-claude-agent-eval-manifest-commands.sh
}
test ! -e "${work}/repo/.git"
run_entry_point tested > "${work}/tested.log" 2>&1 || { cat "${work}/tested.log"; exit 1; }
grep -q "No evaluations selected" "${work}/tested.log"
grep -q 'tests="0"' "${work}/artifacts-tested/junit_claude-eval.xml"
if run_entry_point moved > "${work}/moved.log" 2>&1; then
    cat "${work}/moved.log"; echo "the moved-head run did not fail" >&2; exit 1
fi
grep -q "changed after the job started" "${work}/moved.log"
echo "Entry point selected from JOB_SPEC and the fake GitHub API without .git."
CONTAINER
