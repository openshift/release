#!/bin/bash

export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-begin"

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

# Log rox-ci-image info for traceability.
echo "INFO: rox-ci-image:"
kubectl get imagestreamtag pipeline:root -o jsonpath='{.tag.from.name}{"\n"}Created: {.image.dockerImageMetadata.Created}{"\n"}Labels: {.image.dockerImageMetadata.Config.Labels}{"\n"}' || true
echo "INFO: /i-am-rox-ci-image:"
cat /i-am-rox-ci-image || true

if [[ -f .openshift-ci/begin.sh ]]; then
    exec .openshift-ci/begin.sh
else
    echo "A begin.sh script was not found in the target repo. Which is expected for release branches and migration."
    set -x
    pwd
    ls -l .openshift-ci || true
    set +x
fi
