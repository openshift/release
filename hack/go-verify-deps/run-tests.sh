#!/bin/bash
# Run the go-verify-deps Python unit tests and the embedded step self-test.
# Used by the go-verify-deps-python-test presubmit (change-scoped) and locally.
set -euo pipefail

echo "=== unit tests (python3 -m unittest) ==="
python3 -m unittest discover -s hack/go-verify-deps -p 'test_*.py' -v

echo ""
echo "=== step self-test (go-verify-deps-commands.py --self-test) ==="
python3 ci-operator/step-registry/go/verify-deps/go-verify-deps-commands.py --self-test
