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

# ── Merge abi-pull-secret into the cluster pull secret ───────────────────────
# The abi-pull-secret contains credentials for registry.redhat.io and
# brew.registry.redhat.io which OLM catalog pods need to pull index images.
VAULT_PULL_SECRET="/etc/hypershift-agent-ibmz-credentials/abi-pull-secret"
echo "Merging ${VAULT_PULL_SECRET} into cluster pull secret..."
oc get secret pull-secret -n openshift-config \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/cluster-pull-secret.json
jq -s '.[0].auths * .[1].auths | {auths: .}' \
  /tmp/cluster-pull-secret.json \
  "${VAULT_PULL_SECRET}" > /tmp/merged-pull-secret.json
oc set data secret/pull-secret -n openshift-config \
  --from-file=.dockerconfigjson=/tmp/merged-pull-secret.json
echo "Pull secret updated successfully."

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

# ICSP changes trigger a MachineConfig rollout — nodes reboot to apply the new
# mirror config. OLM catalog pods won't be able to pull registry.redhat.io
# until every node has the updated registries.conf. Wait for MCP to settle.
echo "Waiting for MachineConfigPool to finish applying ICSP..."
for i in $(seq 1 30); do
  UPDATED=$(oc get mcp worker -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || echo "0")
  TOTAL=$(oc get mcp worker -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "1")
  DEGRADED=$(oc get mcp worker -o jsonpath='{.status.degradedMachineCount}' 2>/dev/null || echo "0")
  if [[ "$UPDATED" == "$TOTAL" && "$DEGRADED" == "0" && "$TOTAL" != "0" ]]; then
    echo "  MCP worker is fully updated ($UPDATED/$TOTAL)"
    break
  fi
  echo "  [${i}/30] MCP worker: updated=${UPDATED}, total=${TOTAL}, degraded=${DEGRADED} — retrying in 20s"
  sleep 20
done

# ── Create redhat-operators-stage CatalogSource (same pattern as metallb-commands.sh) ──
echo "Creating redhat-operators-stage CatalogSource..."
oc apply -f - <<EOF
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: redhat-operators-stage
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  publisher: redhat
  displayName: Red Hat Operators v4.22 Stage
  image: quay.io/openshift-release-dev/ocp-release-nightly:iib-int-index-art-operators-4.22
  updateStrategy:
    registryPoll:
      interval: 15m
EOF

# Wait for the CatalogSource to become READY
echo "Waiting for CatalogSource redhat-operators-stage to become READY..."
for i in $(seq 1 30); do
  STATE=$(oc get catalogsource -n openshift-marketplace redhat-operators-stage \
            -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
  [[ "${STATE}" == "READY" ]] && echo "  CatalogSource is READY" && break
  echo "  [${i}/30] state=${STATE:-unknown}, retrying in 15s"
  sleep 15
done

STATE=$(oc get catalogsource -n openshift-marketplace redhat-operators-stage \
          -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
if [[ "${STATE}" != "READY" ]]; then
  echo "ERROR: CatalogSource redhat-operators-stage did not reach READY (last state: ${STATE})"
  echo "--- CatalogSource YAML ---"
  oc get catalogsource redhat-operators-stage -n openshift-marketplace -o yaml
  echo "--- CatalogSource pod logs ---"
  CS_POD=$(oc get pods -n openshift-marketplace \
    -l "olm.catalogSource=redhat-operators-stage" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${CS_POD}" ]]; then
    oc logs -n openshift-marketplace "${CS_POD}" || true
  else
    echo "  No pod found for CatalogSource redhat-operators-stage"
  fi
  echo "--- All CatalogSources ---"
  oc get catalogsource -n openshift-marketplace
  echo "--- openshift-marketplace pods ---"
  oc get pods -n openshift-marketplace -o wide
  exit 1
fi

METALLB_OPERATOR_SUB_SOURCE="redhat-operators-stage"
echo "Using CatalogSource: ${METALLB_OPERATOR_SUB_SOURCE}"

# ── Install metallb-operator via OLM ─────────────────────────────────────────
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
    CSV=$(oc get subscription -n metallb-system metallb-operator -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    continue
  fi

  if [[ $(oc get csv -n metallb-system "${CSV}" -o jsonpath='{.status.phase}' 2>/dev/null || true) == "Succeeded" ]]; then
    echo "metallb-operator is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: metallb-operator is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "ERROR: Failed to deploy metallb-operator"
  echo "--- Subscription ---"
  oc get subscription -n metallb-system metallb-operator -o yaml || true
  echo "--- InstallPlan ---"
  oc get installplan -n metallb-system -o yaml || true
  echo "--- CSV ${CSV} ---"
  oc get csv "${CSV}" -n metallb-system -o yaml || true
  echo "--- CSV ${CSV} describe ---"
  oc describe csv "${CSV}" -n metallb-system || true
  echo "--- metallb-system pods ---"
  oc get pods -n metallb-system -o wide || true
  echo "--- openshift-marketplace pods ---"
  oc get pods -n openshift-marketplace -o wide || true
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
