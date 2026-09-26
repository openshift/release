#!/bin/bash

set -euo pipefail

# Install the Red Hat MetalLB operator (stable channel = latest published CSV)
# and configure an L2 IPAddressPool from the libvirt lease machineNetwork,
# matching the known-good m42lp36 pattern (high .240-.250 range in the /24).

METALLB_NS="${METALLB_NAMESPACE}"
POOL_NAME="${METALLB_POOL_NAME}"
ADV_NAME="${METALLB_ADVERTISEMENT_NAME}"

derive_pool_from_lease() {
  local subnet
  if [[ -z "${LEASED_RESOURCE:-}" ]]; then
    return 1
  fi
  if [[ ! -f "${CLUSTER_PROFILE_DIR}/leases" ]]; then
    return 1
  fi
  if command -v yq-v4 >/dev/null 2>&1; then
    subnet="$(yq-v4 -oy ".\"${LEASED_RESOURCE}\".subnet" "${CLUSTER_PROFILE_DIR}/leases" 2>/dev/null || true)"
  elif command -v python3 >/dev/null 2>&1; then
    subnet="$(python3 - "${CLUSTER_PROFILE_DIR}/leases" "${LEASED_RESOURCE}" <<'PY'
import sys
path, lease = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
# leases file is small YAML: top-level key is lease name, then subnet: N
# Prefer a tiny parse without PyYAML.
import re
# Find the lease block starting at "<lease>:" then first subnet: under it until next top-level key
pat = re.compile(rf'(?m)^{re.escape(lease)}:\s*\n((?:[ \t].*\n)*)')
m = pat.search(text)
if not m:
    sys.exit(1)
block = m.group(1)
sm = re.search(r'(?m)^[ \t]+subnet:\s*["\']?(\d+)', block)
if not sm:
    sys.exit(1)
print(sm.group(1))
PY
)" || true
  fi
  if [[ -z "${subnet:-}" || "${subnet}" == "null" ]]; then
    return 1
  fi
  echo "192.168.${subnet}.${METALLB_POOL_START_HOST}-192.168.${subnet}.${METALLB_POOL_END_HOST}"
}

derive_pool_from_install_config() {
  local cidr octet
  if [[ ! -f "${SHARED_DIR}/install-config.yaml" ]]; then
    return 1
  fi
  cidr="$(awk '/machineNetwork:/{f=1} f && /cidr:/{print; exit}' "${SHARED_DIR}/install-config.yaml" \
    | sed -E 's/.*"?(192\.168\.[0-9]+\.0\/[0-9]+)"?.*/\1/')"
  if [[ -z "${cidr}" ]]; then
    return 1
  fi
  octet="$(echo "${cidr}" | sed -E 's/192\.168\.([0-9]+)\.0\/24/\1/')"
  if [[ -z "${octet}" || ! "${octet}" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  echo "192.168.${octet}.${METALLB_POOL_START_HOST}-192.168.${octet}.${METALLB_POOL_END_HOST}"
}

echo "=== Resolving MetalLB address pool ==="
POOL="${METALLB_ADDRESS_POOL:-}"
if [[ -z "${POOL}" ]]; then
  POOL="$(derive_pool_from_lease || true)"
fi
if [[ -z "${POOL}" ]]; then
  POOL="$(derive_pool_from_install_config || true)"
fi
if [[ -z "${POOL}" ]]; then
  echo "ERROR: could not derive MetalLB pool. Set METALLB_ADDRESS_POOL explicitly," >&2
  echo "  or ensure CLUSTER_PROFILE_DIR/leases + LEASED_RESOURCE or SHARED_DIR/install-config.yaml is available." >&2
  exit 1
fi
echo "Using MetalLB address pool: ${POOL}"

echo "=== Ensuring metallb-operator package is available ==="
PACKAGE_OK=false
for _ in $(seq 1 30); do
  if oc get packagemanifest metallb-operator -n openshift-marketplace >/dev/null 2>&1; then
    PACKAGE_OK=true
    break
  fi
  sleep 10
done
if [[ "${PACKAGE_OK}" != "true" ]]; then
  echo "ERROR: metallb-operator package not found in openshift-marketplace" >&2
  oc get packagemanifest -n openshift-marketplace | head -50 >&2 || true
  exit 1
fi

DEFAULT_CHANNEL="$(oc get packagemanifest metallb-operator -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')"
CHANNEL="${METALLB_CHANNEL}"
if [[ "${CHANNEL}" == "!default" ]]; then
  CHANNEL="${DEFAULT_CHANNEL}"
fi
echo "Subscribing to metallb-operator channel=${CHANNEL} (package default=${DEFAULT_CHANNEL})"

echo "=== Creating ${METALLB_NS} namespace ==="
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${METALLB_NS}
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

echo "=== Creating OperatorGroup ==="
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-operator
  namespace: ${METALLB_NS}
spec: {}
EOF

echo "=== Creating Subscription (Automatic = latest CSV on channel) ==="
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: metallb-operator
  namespace: ${METALLB_NS}
spec:
  channel: ${CHANNEL}
  installPlanApproval: Automatic
  name: metallb-operator
  source: ${METALLB_CATALOG_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

echo "=== Waiting for MetalLB operator CSV to succeed ==="
CSV=""
for i in $(seq 1 60); do
  CSV="$(oc get subscription metallb-operator -n "${METALLB_NS}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
  if [[ -n "${CSV}" ]]; then
    PHASE="$(oc get csv "${CSV}" -n "${METALLB_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    echo "  ${CSV} phase: ${PHASE:-<none>}"
    [[ "${PHASE}" == "Succeeded" ]] && break
  else
    echo "  waiting for installedCSV ... (${i}/60)"
  fi
  sleep 10
done
[[ -n "${CSV}" ]] || { echo "ERROR: metallb-operator CSV not installed" >&2; oc get subscription -n "${METALLB_NS}" -o yaml >&2; exit 1; }
oc wait --for=jsonpath='{.status.phase}'=Succeeded "csv/${CSV}" -n "${METALLB_NS}" --timeout=300s

echo "=== Creating MetalLB instance ==="
oc apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: ${METALLB_NS}
EOF
oc wait --for=condition=Available --timeout=300s -n "${METALLB_NS}" metallb/metallb

echo "=== Creating IPAddressPool ${POOL_NAME} (${POOL}) ==="
oc apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ${POOL_NAME}
  namespace: ${METALLB_NS}
spec:
  autoAssign: true
  addresses:
  - ${POOL}
EOF

echo "=== Creating L2Advertisement ${ADV_NAME} ==="
oc apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ${ADV_NAME}
  namespace: ${METALLB_NS}
spec:
  ipAddressPools:
  - ${POOL_NAME}
EOF

echo "=== Waiting for MetalLB speaker DaemonSet ==="
# Speakers must be Ready before LoadBalancer Services get EXTERNAL-IPs.
for _ in $(seq 1 60); do
  DESIRED="$(oc get daemonset speaker -n "${METALLB_NS}" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)"
  READY="$(oc get daemonset speaker -n "${METALLB_NS}" -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
  echo "  speaker ready ${READY}/${DESIRED}"
  if [[ "${DESIRED}" != "0" && "${READY}" == "${DESIRED}" ]]; then
    break
  fi
  sleep 10
done

echo "=== MetalLB install complete ==="
oc get csv -n "${METALLB_NS}" "${CSV}" -o wide
oc get metallb,ipaddresspool,l2advertisement -n "${METALLB_NS}"
oc get pods -n "${METALLB_NS}" -o wide
echo "MetalLB IP pool: ${POOL}"
