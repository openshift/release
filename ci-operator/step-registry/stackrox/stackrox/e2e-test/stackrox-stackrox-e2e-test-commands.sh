#!/bin/bash
export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-e2e-test"
job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"

# Test Pod DNS config override:
# - log effective config from /etc/resolv.conf
# - sanity resolve quay.io
echo "=== pod-dns: effective /etc/resolv.conf ==="
cat /etc/resolv.conf 2>/dev/null || true
if getent hosts quay.io >/dev/null 2>&1; then
    echo "=== pod-dns: sanity OK (quay.io -> $(getent hosts quay.io | head -1 | awk '{print $1}')) ==="
else
    echo "=== pod-dns: sanity WARN (quay.io not resolvable) ==="
fi

exec .openshift-ci/dispatch.sh "${job}"
