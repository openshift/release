#!/bin/bash
set -euo pipefail

# The helper supervises the sandbox and catches TERM/INT to retain partial results.
# Jira and GitHub credentials are deliberately absent from this step.
exec python3 /opt/agentic-validation/validation.py execute
