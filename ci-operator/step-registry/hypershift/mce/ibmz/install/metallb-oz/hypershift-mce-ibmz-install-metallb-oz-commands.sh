#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Allow callers to redirect oc commands to a different cluster by setting
# INSTALL_KUBECONFIG. Empty = use ci-operator default.
if [[ -n "${INSTALL_KUBECONFIG:-}" ]]; then
  export KUBECONFIG="${INSTALL_KUBECONFIG}"
fi

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
echo "$(date) Waiting for MachineConfigPool to finish applying ICSP..."
MCP_OK=false
for i in $(seq 1 30); do
  UPDATED=$(oc get mcp worker -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || echo "0")
  TOTAL=$(oc get mcp worker -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "1")
  DEGRADED=$(oc get mcp worker -o jsonpath='{.status.degradedMachineCount}' 2>/dev/null || echo "0")
  if [[ "$UPDATED" == "$TOTAL" && "$DEGRADED" == "0" && "$TOTAL" != "0" ]]; then
    echo "$(date) MCP worker is fully updated ($UPDATED/$TOTAL)"
    MCP_OK=true
    break
  fi
  echo "$(date) [${i}/30] MCP worker: updated=${UPDATED}, total=${TOTAL}, degraded=${DEGRADED} — retrying in 20s"
  sleep 20
done
if [[ "${MCP_OK}" != "true" ]]; then
  echo "$(date) ERROR: MachineConfigPool worker did not converge after ICSP within timeout"
  oc get mcp -o wide || true
  oc describe mcp worker || true
  exit 1
fi

# Catalog selection (matches ref docs; same OZ fallback pattern as metallb-commands.sh):
# 1. Honor an explicit non-default METALLB_OPERATOR_SUB_SOURCE from the caller.
# 2. Otherwise create redhat-operators-stage (IIB) — required on OZ where the
#    built-in redhat-operators catalog cannot pull metallb-operator reliably.
REQUESTED_SOURCE="${METALLB_OPERATOR_SUB_SOURCE:-redhat-operators}"
echo "$(date) Requested METALLB_OPERATOR_SUB_SOURCE=${REQUESTED_SOURCE}"

if [[ "${REQUESTED_SOURCE}" != "redhat-operators" && "${REQUESTED_SOURCE}" != "redhat-operators-stage" ]]; then
  echo "$(date) Using caller-provided CatalogSource as-is: ${REQUESTED_SOURCE}"
  METALLB_OPERATOR_SUB_SOURCE="${REQUESTED_SOURCE}"
else
  echo "$(date) Creating redhat-operators-stage CatalogSource (OZ fallback)..."
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
  displayName: Red Hat Operators v4.20 Stage
  image: quay.io/openshift-release-dev/ocp-release-nightly:iib-int-index-art-operators-4.20
  updateStrategy:
    registryPoll:
      interval: 15m
EOF

  echo "$(date) Waiting for CatalogSource redhat-operators-stage to become READY..."
  for i in $(seq 1 30); do
    STATE=$(oc get catalogsource -n openshift-marketplace redhat-operators-stage \
              -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
    [[ "${STATE}" == "READY" ]] && echo "$(date) CatalogSource is READY" && break
    echo "$(date) [${i}/30] state=${STATE:-unknown}, retrying in 15s"
    sleep 15
  done

  STATE=$(oc get catalogsource -n openshift-marketplace redhat-operators-stage \
            -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)
  if [[ "${STATE}" != "READY" ]]; then
    echo "$(date) ERROR: CatalogSource redhat-operators-stage did not reach READY (last state: ${STATE})"
    oc get catalogsource redhat-operators-stage -n openshift-marketplace -o yaml || true
    CS_POD=$(oc get pods -n openshift-marketplace \
      -l "olm.catalogSource=redhat-operators-stage" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [[ -n "${CS_POD}" ]] && oc logs -n openshift-marketplace "${CS_POD}" || true
    oc get catalogsource -n openshift-marketplace || true
    oc get pods -n openshift-marketplace -o wide || true
    exit 1
  fi
  METALLB_OPERATOR_SUB_SOURCE="redhat-operators-stage"
fi
echo "$(date) Using CatalogSource: ${METALLB_OPERATOR_SUB_SOURCE}"

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

# Resolve the IP address pool range.
# Priority:
#   1. METALLB_MGMT_IPS env var, if explicitly set by the caller.
#   2. A default derived from the cluster/environment (extend this if-block
#      as new environments are added).
if [[ -n "${METALLB_MGMT_IPS:-}" ]]; then
  IP_POOL="${METALLB_MGMT_IPS}"
  echo "$(date) Using METALLB_MGMT_IPS override: ${IP_POOL}"
else
  # Prefer InternalIP from the API (column layout of `oc get no -o wide` varies).
  NODE_IP=$(oc get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)
  echo "$(date) Detected node InternalIP: ${NODE_IP:-<empty>}"
  oc get nodes -o wide || true
  # Only the two known OZ libvirt lease subnets are valid. Never default to
  # 192.168.3.* on unknown input — a wrong VIP makes the guest API unreachable.
  if [[ "${NODE_IP}" == 192.168.2.* ]]; then
    IP_POOL="192.168.2.53-192.168.2.54"
  elif [[ "${NODE_IP}" == 192.168.3.* ]]; then
    IP_POOL="192.168.3.53-192.168.3.54"
  else
    echo "$(date) ERROR: Unrecognised node InternalIP '${NODE_IP}' — expected 192.168.2.x or 192.168.3.x"
    echo "$(date) Set METALLB_MGMT_IPS explicitly if this environment uses a different subnet."
    exit 1
  fi
fi
echo "$(date) IPAddressPool range: ${IP_POOL}"

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb
  namespace: metallb-system
spec:
  addresses:
  - ${IP_POOL}
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

# ── Wait for MetalLB controller + speaker pods to be Ready ───────────────────
# Empty pod list used to look "successful" (NOT_READY empty). Require at least
# one Ready pod and fail hard on timeout — otherwise HCP LoadBalancer VIP never
# gets announced and guest API probing falls back to flaky LPAR NodePort.
echo "$(date) Waiting for MetalLB pods in metallb-system to be Ready..."
oc get metallb,ipaddresspool,l2advertisement -n metallb-system -o wide || true
METALLB_WAIT=180
METALLB_INTERVAL=10
METALLB_ELAPSED=0
METALLB_OK=false

while [[ ${METALLB_ELAPSED} -lt ${METALLB_WAIT} ]]; do
  POD_COUNT=$(oc get pods -n metallb-system --no-headers 2>/dev/null | grep -cvE 'Completed|Error' || true)
  POD_COUNT=${POD_COUNT:-0}
  if [[ ${POD_COUNT} -eq 0 ]]; then
    echo "$(date) No metallb-system pods yet (${METALLB_ELAPSED}s/${METALLB_WAIT}s)"
  else
    NOT_READY=""
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      pod=$(awk '{print $1}' <<< "${line}")
      ready_col=$(awk '{print $2}' <<< "${line}")   # e.g. 1/1
      status_col=$(awk '{print $3}' <<< "${line}")
      ready_cond=$(oc get po -n metallb-system "${pod}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
      echo "$(date)   pod=${pod} ready=${ready_col} phase=${status_col} Ready=${ready_cond:-?}"
      if [[ "${ready_cond}" != "True" ]]; then
        NOT_READY="${NOT_READY} ${pod}"
      fi
    done < <(oc get pods -n metallb-system --no-headers 2>/dev/null | grep -vE 'Completed' || true)

    if [[ -z "${NOT_READY}" ]]; then
      echo "$(date) All ${POD_COUNT} metallb-system pods are Ready"
      oc get pods -n metallb-system -o wide || true
      METALLB_OK=true
      break
    fi
    echo "$(date) MetalLB pods not Ready yet:${NOT_READY}"
  fi
  sleep ${METALLB_INTERVAL}
  METALLB_ELAPSED=$((METALLB_ELAPSED + METALLB_INTERVAL))
done

if [[ "${METALLB_OK}" != "true" ]]; then
  echo "$(date) ERROR: MetalLB pods did not become Ready within ${METALLB_WAIT}s"
  oc get pods -n metallb-system -o wide || true
  oc get metallb,ipaddresspool,l2advertisement -n metallb-system -o yaml || true
  oc describe pods -n metallb-system || true
  exit 1
fi

echo "$(date) MetalLB install and IP pool configuration completed (pool=${IP_POOL})"
