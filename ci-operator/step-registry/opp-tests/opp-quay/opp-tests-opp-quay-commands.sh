#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit 2>/dev/null || true

opp-tests run-suite opp/quay
true
