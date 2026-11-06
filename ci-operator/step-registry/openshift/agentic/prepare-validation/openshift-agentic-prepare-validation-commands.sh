#!/bin/bash
set -euo pipefail

# Preparation receives Jira/model credentials. Only checked plans and source
# references enter SHARED_DIR; raw issue bodies, tokens and prompts stay private.
export VALIDATION_SOURCE_DIR="${PWD}"
exec python3 /opt/agentic-validation/openshift-agentic-validate-commands.py prepare
