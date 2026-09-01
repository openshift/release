#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit 2>/dev/null || true

stolostron-policy-collection run-suite policy-collection/nist
true
