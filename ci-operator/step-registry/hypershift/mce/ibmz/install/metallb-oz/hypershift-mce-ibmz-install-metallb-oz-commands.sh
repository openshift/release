#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Allow callers to redirect oc commands to a different cluster by setting
# INSTALL_KUBECONFIG. Empty = use ci-operator default.
if [[ -n "${INSTALL_KUBECONFIG:-}" ]]; then
  export KUBECONFIG="${INSTALL_KUBECONFIG}"
fi

# ── Install metallb-operator via OLM ─────────────────────────────────────────

echo "Installing metallb-operator (stable, redhat-operators) into metallb-system"

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
  source: redhat-operators
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
  - 192.168.2.53-192.168.2.53
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
