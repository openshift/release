#!/bin/bash
set -euo pipefail

# Runs the openspec QE workflow end to end with the Codex CLI.
# The runner lives in the openspec-agent-worker image.
exec /opt/openspec-src/scripts/ci/run-openspec-workflow.sh qe
