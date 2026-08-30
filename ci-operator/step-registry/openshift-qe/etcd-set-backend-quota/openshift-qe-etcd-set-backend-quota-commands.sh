#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# The default OCP etcd backend quota is 8 GiB; nothing to do if we're staying there.
# Keeping this a no-op at 8 lets the same step be reused (harmlessly) by the 8GB job.
if [[ "${ETCD_BACKEND_QUOTA_GIB}" -eq 8 ]]; then
    echo "ETCD_BACKEND_QUOTA_GIB=8 (default); leaving etcd backend quota unchanged."
    exit 0
fi

# backendQuotaGiB is only exposed on newer releases; fail clearly if the field is absent
# rather than silently leaving the quota at the 8 GiB default.
if ! oc explain etcd.spec.backendQuotaGiB >/dev/null 2>&1; then
    echo "ERROR: etcd.spec.backendQuotaGiB is not available on this cluster/release." >&2
    echo "The etcd backend quota cannot be tuned here; verify the payload supports it." >&2
    exit 1
fi

echo "Setting etcd backendQuotaGiB to ${ETCD_BACKEND_QUOTA_GIB}..."
oc patch etcd cluster --type=merge \
  --patch "{\"spec\":{\"backendQuotaGiB\": ${ETCD_BACKEND_QUOTA_GIB}}}"

# Give the operator a moment to observe the change and start a new revision rollout.
# This may complete quickly, so do not treat a missed transition as fatal.
oc wait --timeout=5m --for=condition=Progressing=True clusteroperator/etcd \
  || echo "etcd did not report Progressing=True (may have converged quickly); continuing."

# Wait for the new etcd static-pod revision to roll out across all control-plane nodes.
oc wait --timeout=30m --for=condition=Progressing=False clusteroperator/etcd
oc wait --timeout=10m --for=condition=Available=True    clusteroperator/etcd
oc wait --timeout=10m --for=condition=Degraded=False    clusteroperator/etcd

# Verify the value actually applied and report per-node revisions for the log.
APPLIED=$(oc get etcd cluster -o jsonpath='{.spec.backendQuotaGiB}')
echo "etcd backendQuotaGiB is now: ${APPLIED}"
oc get etcd cluster -o jsonpath='{range .status.nodeStatuses[*]}{.nodeName}{" -> revision "}{.currentRevision}{"\n"}{end}'
[[ "${APPLIED}" -eq "${ETCD_BACKEND_QUOTA_GIB}" ]]
