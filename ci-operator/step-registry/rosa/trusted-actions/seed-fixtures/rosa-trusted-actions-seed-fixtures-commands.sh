#!/usr/bin/env bash
#
# Creates the objects the writing half of the Trusted Actions e2e suite acts
# on, and records their names in ${SHARED_DIR} for the test step to read.
#
# This step holds the cluster-admin kubeconfig on purpose, and the test step
# deliberately does not: RTA obtains cluster access from backplane, scoped and
# time-limited, so the thing under test cannot be the thing that creates its
# own fixtures. Seeding here is what keeps that boundary intact while still
# giving 'patch' and 'delete' something safe to act on.
#
# Everything created lives in one namespace that exists only for this run, so
# no test can reach an object it did not create.

set -euo pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Private clusters are reached through the corp proxy; the credentials step
# writes this file when that applies. Harmless when it does not exist.
if [[ -s "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/proxy-conf.sh"
fi

log() { echo -e "\033[1m$(date "+%Y-%m-%dT%H:%M:%S")  ${*}\033[0m" >&2; }

# Suffixed per run. The namespace is normally fresh, but a job retried against
# a reused cluster must not act on an object an earlier attempt left behind —
# the 'patch' test asserts on a value it just wrote, and would otherwise be
# able to pass against a stale object.
SUFFIX="$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CONFIGMAP="e2e-patch-${SUFFIX}"
POD="e2e-delete-${SUFFIX}"

log "Seeding fixtures in namespace ${FIXTURE_NAMESPACE}"

# Applied rather than created so a retry against the same cluster converges
# instead of failing on an existing namespace.
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${FIXTURE_NAMESPACE}
  labels:
    rosa-trusted-actions.openshift.io/e2e: "true"
EOF

oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIGMAP}
  namespace: ${FIXTURE_NAMESPACE}
data:
  seeded: "true"
EOF

# The security context is spelled out so the pod is admissible under the
# restricted pod-security profile without relying on what the namespace
# happens to enforce.
oc apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${FIXTURE_NAMESPACE}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
  containers:
  - name: sleep
    image: ${FIXTURE_POD_IMAGE}
    command: ["/bin/sleep", "infinity"]
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      capabilities:
        drop: ["ALL"]
      seccompProfile:
        type: RuntimeDefault
EOF

# Waited for, but not required: 'delete' removes the object whatever phase it
# is in, and failing the whole job because an image pull was slow would turn a
# cluster hiccup into a red suite.
if ! oc wait --for=condition=Ready "pod/${POD}" -n "${FIXTURE_NAMESPACE}" --timeout="${FIXTURE_READY_TIMEOUT}"; then
  log "WARNING: ${POD} is not ready; continuing, the delete test does not require a running pod"
fi

echo "${FIXTURE_NAMESPACE}" > "${SHARED_DIR}/e2e-fixture-namespace"
echo "${CONFIGMAP}" > "${SHARED_DIR}/e2e-fixture-configmap"
echo "${POD}" > "${SHARED_DIR}/e2e-fixture-pod"

log "Seeded namespace=${FIXTURE_NAMESPACE} configmap=${CONFIGMAP} pod=${POD}"
