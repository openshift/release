#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# This step always targets the infra cluster. Use INSTALL_KUBECONFIG if
# explicitly set; otherwise fall back to $SHARED_DIR/infra-kubeconfig.
# NOTE: env var defaults in ref YAMLs are not shell-expanded, so the path
# cannot be defaulted in the ref — we resolve it here at runtime instead.
EFFECTIVE_KUBECONFIG="${INSTALL_KUBECONFIG:-${SHARED_DIR}/infra-kubeconfig}"
if [[ ! -f "${EFFECTIVE_KUBECONFIG}" ]]; then
  echo "ERROR: infra kubeconfig not found at ${EFFECTIVE_KUBECONFIG}"
  exit 1
fi
export KUBECONFIG="${EFFECTIVE_KUBECONFIG}"

# ── Ensure brew-registry ICSP is present so registry.redhat.io is reachable ──
oc apply -f - <<EOF
---
apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
  name: brew-registry
spec:
  repositoryDigestMirrors:
  - mirrors:
    - brew.registry.redhat.io
    source: registry.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry.stage.redhat.io
  - mirrors:
    - brew.registry.redhat.io
    source: registry-proxy.engineering.redhat.com
EOF


# ── Install metallb-operator via OLM ─────────────────────────────────────────

# If the default CatalogSource does not carry metallb-operator, create a
# pinned CatalogSource from the v4.22 index image and use that instead.
FALLBACK_CATALOG="metallb-operator-catalog"
# Use registry.redhat.io — accessible via the brew-registry ICSP mirror.
FALLBACK_IMAGE="registry.redhat.io/redhat/redhat-operator-index:v4.22"

if ! oc get packagemanifest -n openshift-marketplace metallb-operator \
     --field-selector "status.catalogSource=${METALLB_OPERATOR_SUB_SOURCE}" \
     --ignore-not-found -o name 2>/dev/null | grep -q metallb-operator; then
  echo "metallb-operator not found in '${METALLB_OPERATOR_SUB_SOURCE}' — creating fallback CatalogSource ${FALLBACK_CATALOG}"
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${FALLBACK_CATALOG}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${FALLBACK_IMAGE}
  displayName: "Red Hat Operators - MetalLB"
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

  # Wait for the fallback catalog to become READY
  echo "Waiting for CatalogSource ${FALLBACK_CATALOG} to become ready..."
  for i in $(seq 1 20); do
    STATE=$(oc get catalogsource -n openshift-marketplace "${FALLBACK_CATALOG}" \
              -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
    [[ "${STATE}" == "READY" ]] && break
    echo "  [${i}/20] state=${STATE:-unknown}, retrying in 15s"
    sleep 15
  done
  STATE=$(oc get catalogsource -n openshift-marketplace "${FALLBACK_CATALOG}" \
            -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
  if [[ "${STATE}" != "READY" ]]; then
    echo "Error: CatalogSource ${FALLBACK_CATALOG} did not reach READY state (last state: ${STATE})"
    oc get catalogsource -n openshift-marketplace "${FALLBACK_CATALOG}" -o yaml
    exit 1
  fi
  METALLB_OPERATOR_SUB_SOURCE="${FALLBACK_CATALOG}"
else
  echo "metallb-operator found in '${METALLB_OPERATOR_SUB_SOURCE}' — using default CatalogSource"
fi

echo "Installing metallb-operator (stable, ${METALLB_OPERATOR_SUB_SOURCE}) into metallb-system"

# Create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# Deploy OperatorGroup
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-system
  namespace: metallb-system
spec: {}
EOF

# Subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: metallb-operator
  namespace: metallb-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: metallb-operator
  source: "${METALLB_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

RETRIES=30
CSV=
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    CSV=$(oc get subscription -n metallb-system metallb-operator -o jsonpath='{.status.installedCSV}')
    continue
  fi

  if [[ $(oc get csv -n metallb-system ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "metallb-operator is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: metallb-operator is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy metallb-operator"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n metallb-system -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n metallb-system
  exit 1
fi

echo "successfully installed metallb-operator"

# ── Create MetalLB CR and configure IP pool ───────────────────────────────────

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
EOF

echo "Configure IPAddressPool"
oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb
  namespace: metallb-system
spec:
  addresses:
  - 192.168.2.54-192.168.2.54
EOF

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
   - metallb
EOF
