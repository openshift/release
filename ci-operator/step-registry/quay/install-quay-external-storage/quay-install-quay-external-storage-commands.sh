#!/bin/bash
set -euo pipefail

# Deploy a QuayRegistry backed by externally provisioned object storage. The Quay
# operator is already installed (AllNamespaces, by quay-operator-upgrade-install-
# source), so this step only creates the QuayRegistry CR in namespace "quay" with
# objectstorage unmanaged. The storage backend is supplied by a
# provision-storage-<backend> step as ${SHARED_DIR}/quay-storage-config.yaml, so
# this step is backend-agnostic (S3 today, GCS/Azure later with no change here).
#
# Security (CLAUDE.md): runs without `set -x`; the storage contract carries the
# object-storage secret key, so it is folded into config.yaml by redirect/append
# only, never echoed, and the config bundle lives in a Secret.

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-install-quay-external-storage"
mkdir -p "${ARTIFACT_DIR}"

NAMESPACE="${QUAY_UPGRADE_QUAY_NAMESPACE:-quay}"
REGISTRY="${QUAY_UPGRADE_QUAY_REGISTRY:-quay}"
TIMEOUT="${QUAY_INSTALL_READINESS_TIMEOUT:-15m}"
[[ "${TIMEOUT}" =~ ^([1-9][0-9]*)([smh])$ ]] || { echo "ERROR: QUAY_INSTALL_READINESS_TIMEOUT must be a positive Ns, Nm, or Nh duration" >&2; exit 1; }
case "${BASH_REMATCH[2]}" in s) seconds="${BASH_REMATCH[1]}";; m) seconds="$((BASH_REMATCH[1] * 60))";; h) seconds="$((BASH_REMATCH[1] * 3600))";; esac

STORAGE_FRAGMENT="${SHARED_DIR}/quay-storage-config.yaml"
[[ -s "${STORAGE_FRAGMENT}" ]] || { echo "ERROR: missing storage contract ${STORAGE_FRAGMENT}; run a provision-storage-<backend> step first" >&2; exit 1; }

echo "Waiting for QuayRegistry CRD to be available..." >&2
for _ in $(seq 1 30); do
  oc get crd quayregistries.quay.redhat.com &>/dev/null && break
  sleep 5
done
oc get crd quayregistries.quay.redhat.com &>/dev/null || { echo "ERROR: QuayRegistry CRD not available; is the Quay operator installed?" >&2; exit 1; }

# Build the config bundle: initialization flags first, then append the storage
# contract. The two documents have disjoint top-level keys, so a plain append
# yields a single valid config.yaml without needing yq.
cat >config.yaml <<EOF
FEATURE_USER_INITIALIZE: true
SUPER_USERS:
  - admin
EOF
cat "${STORAGE_FRAGMENT}" >>config.yaml

oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -
oc create secret generic -n "${NAMESPACE}" config-bundle-secret \
  --from-file config.yaml=./config.yaml \
  --dry-run=client -o yaml | oc apply -f -

echo "Creating QuayRegistry ${NAMESPACE}/${REGISTRY} with external object storage..." >&2
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: ${REGISTRY}
  namespace: ${NAMESPACE}
spec:
  configBundleSecret: config-bundle-secret
  components:
  - kind: objectstorage
    managed: false
  - kind: monitoring
    managed: false
  - kind: horizontalpodautoscaler
    managed: false
  - kind: quay
    managed: true
  - kind: mirror
    managed: true
  - kind: clair
    managed: true
  - kind: tls
    managed: true
  - kind: route
    managed: true
EOF

echo "Waiting for Quay to become ready (timeout: ${TIMEOUT})..." >&2
deadline=$(( $(date +%s) + seconds ))
while (( $(date +%s) < deadline )); do
  status="$(oc -n "${NAMESPACE}" get quayregistry "${REGISTRY}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [[ "${status}" == "True" ]]; then
    echo "Quay is ready" >&2
    oc -n "${NAMESPACE}" get quayregistries -o yaml >"${ARTIFACT_DIR}/quayregistries.yaml" || true
    exit 0
  fi
  sleep 10
done

echo "ERROR: QuayRegistry ${NAMESPACE}/${REGISTRY} did not become Available within ${TIMEOUT}" >&2
oc -n "${NAMESPACE}" get quayregistry "${REGISTRY}" -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}) {.message}{"\n"}{end}' >&2 2>/dev/null || true
oc -n "${NAMESPACE}" get quayregistries -o yaml >"${ARTIFACT_DIR}/quayregistries.yaml" || true
oc -n "${NAMESPACE}" get pods -o yaml >"${ARTIFACT_DIR}/quay-pods.yaml" || true
oc -n "${NAMESPACE}" get events --sort-by='.lastTimestamp' -o yaml >"${ARTIFACT_DIR}/quay-events.yaml" || true
oc -n "${NAMESPACE}" get deployments -o yaml >"${ARTIFACT_DIR}/quay-deployments.yaml" || true
exit 1
