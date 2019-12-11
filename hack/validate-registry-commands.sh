#!/usr/bin/env bash
set -euo pipefail

# This script checks all shell scripts in the step registry and errors if shellcheck detects error or warning level syntax issues

find ci-operator/step-registry -name "*.sh" -print0 | xargs -0 -n1 shellcheck -S warning
