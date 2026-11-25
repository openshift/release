#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# The TLS scanner connects to pods in the NROP namespace (e.g. the secondary
# scheduler metrics endpoint on port 10259) over the pod network. NROP
# namespaces enforce NetworkPolicy that denies ingress from other namespaces,
# so the scanner running in its own namespace cannot reach those pods.
#
# NetworkPolicies are additive: this creates a policy that allows ingress to the
# scheduler pods from both the NROP namespace and the scanner namespace, so the
# scan can complete without loosening the existing isolation for other traffic.

SCAN_NAMESPACE="${SCAN_NAMESPACE:-openshift-numaresources}"
SCANNER_NAMESPACE="${SCANNER_NAMESPACE:-tls-scanner}"
SCHEDULER_POD_LABEL_KEY="${SCHEDULER_POD_LABEL_KEY:-app}"
SCHEDULER_POD_LABEL_VALUE="${SCHEDULER_POD_LABEL_VALUE:-secondary-scheduler}"
SCHEDULER_PORT="${SCHEDULER_PORT:-10259}"

# The scanner runs pod-networked in SCANNER_NAMESPACE so the namespaceSelector
# below matches its traffic. In that mode the tls-scanner-run step does not
# create the namespace itself, so ensure it exists here before the scan.
echo "Ensuring scanner namespace ${SCANNER_NAMESPACE} exists..."
oc create namespace "${SCANNER_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

echo "Allowing TLS scanner (ns: ${SCANNER_NAMESPACE}) ingress to ${SCHEDULER_POD_LABEL_KEY}=${SCHEDULER_POD_LABEL_VALUE} pods on port ${SCHEDULER_PORT} in ${SCAN_NAMESPACE}..."

cat <<EOF | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: scheduler-ingress-tls-scan
  namespace: ${SCAN_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      ${SCHEDULER_POD_LABEL_KEY}: ${SCHEDULER_POD_LABEL_VALUE}
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${SCAN_NAMESPACE}
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: ${SCANNER_NAMESPACE}
    ports:
    - protocol: TCP
      port: ${SCHEDULER_PORT}
  policyTypes:
  - Ingress
EOF

echo "NetworkPolicy scheduler-ingress-tls-scan applied in ${SCAN_NAMESPACE}:"
oc get networkpolicy scheduler-ingress-tls-scan -n "${SCAN_NAMESPACE}"
