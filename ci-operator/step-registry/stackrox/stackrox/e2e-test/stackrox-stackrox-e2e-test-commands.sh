#!/bin/bash
export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-e2e-test"

# Pod DNS report (dnsConfig test: this step pod runs with nameservers [8.8.8.8],
# dnsPolicy None - build01 CoreDNS flakiness 2026-09-11/12). /etc/resolv.conf
# is a read-only bind mount in k8s pods, so the pod spec "dnsConfig" field is
# the mechanism; log the effective config + a sanity probe.
echo "=== pod-dns: effective /etc/resolv.conf ==="
cat /etc/resolv.conf 2>/dev/null || true
if getent hosts quay.io >/dev/null 2>&1; then
    echo "=== pod-dns: sanity OK (quay.io -> $(getent hosts quay.io | head -1 | awk '{print $1}')) ==="
else
    echo "=== pod-dns: sanity WARN (quay.io not resolvable) ==="
fi

job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"
exec .openshift-ci/dispatch.sh "${job}"
