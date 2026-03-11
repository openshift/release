#!/bin/bash

set -euo pipefail

# Target: guest cluster (Cluster A) - creating external infra kubeconfig
if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: Guest cluster (Cluster A) kubeconfig not found at ${SHARED_DIR}/kubeconfig"
  exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

EXTERNAL_INFRA_NS="${EXTERNAL_INFRA_NS:-"guest-external-infra-ns"}"
SA_NAME="kv-external-infra-sa"
RESTRICTED_KUBECONFIG="${SHARED_DIR}/external_infra_kubeconfig"

echo "Creating namespace ${EXTERNAL_INFRA_NS} on Cluster A for external infrastructure"
oc create ns "${EXTERNAL_INFRA_NS}"

echo "Creating service account ${SA_NAME}"
oc create serviceaccount "${SA_NAME}" -n "${EXTERNAL_INFRA_NS}"

echo "Creating token for service account"
TOKEN=$(oc create token "${SA_NAME}" -n "${EXTERNAL_INFRA_NS}" --duration 8h)

echo "Waiting for kube-root-ca.crt configmap to be available"
for i in $(seq 30); do
  if oc get configmap kube-root-ca.crt -n "${EXTERNAL_INFRA_NS}" &>/dev/null; then
    break
  fi
  echo "Attempt ${i}/30: kube-root-ca.crt not yet available, retrying in 5s..."
  sleep 5
done
oc get configmap kube-root-ca.crt -n "${EXTERNAL_INFRA_NS}" -o "jsonpath={.data['ca\.crt']}" > /tmp/ca.crt

CURRENT_CONTEXT_NAME=$(oc config current-context)
INFRA_CLUSTER_NAME=$(oc config view -o json | jq -r --arg CURRENT_CONTEXT_NAME "$CURRENT_CONTEXT_NAME" '.contexts[] | select(.name==$CURRENT_CONTEXT_NAME).context.cluster')
INFRA_CLUSTER_API=$(oc config view -o json | jq -r --arg INFRA_CLUSTER_NAME "$INFRA_CLUSTER_NAME" '.clusters[] | select(.name==$INFRA_CLUSTER_NAME).cluster.server')

echo "Creating restricted kubeconfig for external infra cluster"
touch "${RESTRICTED_KUBECONFIG}"

oc config set-cluster "${INFRA_CLUSTER_NAME}" \
  --kubeconfig="${RESTRICTED_KUBECONFIG}" \
  --server="${INFRA_CLUSTER_API}" \
  --certificate-authority=/tmp/ca.crt \
  --embed-certs=true

oc config set-credentials "${SA_NAME}" \
  --kubeconfig="${RESTRICTED_KUBECONFIG}" \
  --token="${TOKEN}"

oc config set-context "${INFRA_CLUSTER_NAME}" \
  --kubeconfig="${RESTRICTED_KUBECONFIG}" \
  --user="${SA_NAME}" \
  --cluster="${INFRA_CLUSTER_NAME}"

oc config use-context "${INFRA_CLUSTER_NAME}" --kubeconfig="${RESTRICTED_KUBECONFIG}"

echo "Creating RBAC role for external infrastructure"
oc apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: kv-external-infra-role
  namespace: ${EXTERNAL_INFRA_NS}
rules:
  - apiGroups:
      - kubevirt.io
    resources:
      - virtualmachines
      - virtualmachines/finalizers
      - virtualmachineinstances
    verbs:
      - '*'
  - apiGroups:
      - cdi.kubevirt.io
    resources:
      - datavolumes
    verbs:
      - '*'
  - apiGroups:
      - ''
    resources:
      - services
    verbs:
      - '*'
  - apiGroups:
      - discovery.k8s.io
    resources:
      - endpointslices
      - endpointslices/restricted
    verbs:
      - '*'
  - apiGroups:
      - route.openshift.io
    resources:
      - routes
      - routes/custom-host
    verbs:
      - '*'
  - apiGroups:
      - ''
    resources:
      - secrets
    verbs:
      - '*'
  - apiGroups:
      - k8s.ovn.org
    resources:
      - egressfirewalls
    verbs:
      - '*'
  - apiGroups:
    - snapshot.storage.k8s.io
    resources:
    - volumesnapshots
    verbs:
    - get
    - create
    - delete
  - apiGroups:
    - ''
    resources:
    - persistentvolumeclaims
    verbs:
    - get
EOF

echo "Creating RBAC role binding"
oc apply -f - <<EOF
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: kv-external-infra-rolebinding
  namespace: ${EXTERNAL_INFRA_NS}
subjects:
  - kind: ServiceAccount
    name: ${SA_NAME}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: kv-external-infra-role
EOF

echo "External infra kubeconfig saved to ${RESTRICTED_KUBECONFIG}"
echo "Verifying restricted kubeconfig connectivity"
oc --kubeconfig="${RESTRICTED_KUBECONFIG}" auth can-i --list --namespace "${EXTERNAL_INFRA_NS}" | head -20
