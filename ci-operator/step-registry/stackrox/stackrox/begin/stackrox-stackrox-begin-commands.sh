#!/bin/bash

export OPENSHIFT_CI_STEP_NAME="stackrox-stackrox-begin"

# Fallback DNS workaround. build01's CoreDNS has been flaky (2026-09-11/12 batch:
# 'Unable to resolve host' for quay.io, *.elb.amazonaws.com, oauth2.googleapis.com).
# Keep the existing /etc/resolv.conf (in-cluster names + search domains served by
# the primary nameserver) and append a public fallback LAST: glibc only consults
# the next nameserver on timeout/SERVFAIL, so in-cluster lookups keep the primary.
# Logs what it finds and how it applied the change so we can trim to the minimum.
setup_fallback_dns() {
    local target="8.8.8.8"
    echo "=== setup_fallback_dns: before ==="
    ls -la /etc/resolv.conf 2>&1 || true
    readlink -f /etc/resolv.conf 2>/dev/null || true
    cat /etc/resolv.conf 2>/dev/null || true
    if grep -q "nameserver ${target}" /etc/resolv.conf 2>/dev/null; then
        echo "=== setup_fallback_dns: ${target} already present, no change ==="
        return 0
    fi
    if echo "nameserver ${target}" >> /etc/resolv.conf 2>/dev/null; then
        echo "=== setup_fallback_dns: OK via in-place append ==="
    else
        echo "=== setup_fallback_dns: in-place append failed, trying rm+rewrite ==="
        local pristine=/tmp/resolv.conf.pristine
        cp /etc/resolv.conf "${pristine}" 2>/dev/null || true
        rm -f /etc/resolv.conf 2>/dev/null || true
        if { cat "${pristine}" 2>/dev/null; echo "nameserver ${target}"; } > /etc/resolv.conf 2>/dev/null; then
            echo "=== setup_fallback_dns: OK via rm+rewrite ==="
        else
            echo "=== setup_fallback_dns: FAILED, leaving /etc/resolv.conf as-is ==="
            return 0
        fi
    fi
    echo "=== setup_fallback_dns: after ==="
    cat /etc/resolv.conf 2>/dev/null || true
    if getent hosts quay.io >/dev/null 2>&1; then
        echo "=== setup_fallback_dns: sanity OK (quay.io resolved) ==="
    else
        echo "=== setup_fallback_dns: sanity WARN (quay.io not resolvable right now) ==="
    fi
    return 0
}
setup_fallback_dns

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
