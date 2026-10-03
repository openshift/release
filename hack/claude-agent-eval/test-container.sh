#!/bin/bash
# Run offline runner tests with the same image used by the eval step.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
engine="${CONTAINER_ENGINE:-podman}"
image="${EVAL_TEST_IMAGE:-registry.ci.openshift.org/ci/claude-ai-helpers:latest}"

# Override EVAL_TEST_IMAGE with an image digest to reproduce a particular CI run.
"${engine}" run --rm --network=none --platform linux/amd64 \
    --volume "${repo_root}:/release:ro" --workdir /release \
    --env PYTHONDONTWRITEBYTECODE=1 --entrypoint /bin/bash "${image}" -c '
        set -euo pipefail
        python3 hack/claude-agent-eval/sync_commands.py --check
        python3 -m unittest discover -s hack/claude-agent-eval -p "test_*.py" -v
    '
