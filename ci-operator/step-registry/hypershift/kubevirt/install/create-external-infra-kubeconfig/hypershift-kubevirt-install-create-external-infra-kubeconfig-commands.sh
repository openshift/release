#!/bin/bash

set -exuo pipefail

EXTERNAL_INFRA_NS="${EXTERNAL_INFRA_NS:-"guest-external-infra-ns"}"
SA_NAME="kv-external-infra-sa"

oc create ns ${EXTERNAL_INFRA_NS}
oc create serviceaccount ${SA_NAME} -n ${EXTERNAL_INFRA_NS}

TOKEN_SA_SECRET=$(oc get secrets -n ${EXTERNAL_INFRA_NS} -o json | jq -r --arg SA_NAME "$SA_NAME" \
  '.items[] | select(.metadata.annotations."kubernetes.io/service-account.name"==$SA_NAME and .type=="kubernetes.io/service-account-token").metadata.name')

TOKEN=$(oc get secret ${TOKEN_SA_SECRET} -n ${EXTERNAL_INFRA_NS} -o jsonpath='{.data.token}' | base64 -d)

oc get secret ${TOKEN_SA_SECRET} -n ${EXTERNAL_INFRA_NS} -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/ca.crt

CURRENT_CONTEXT_NAME=$(oc config current-context)
INFRA_CLUSTER_NAME=$(oc config view -o json | jq -r --arg CURRENT_CONTEXT_NAME "$CURRENT_CONTEXT_NAME" '.contexts[] | select(.name==$CURRENT_CONTEXT_NAME).context.cluster')
INFRA_CLUSTER_API=$(oc config view -o json | jq -r --arg INFRA_CLUSTER_NAME "$INFRA_CLUSTER_NAME" '.clusters[] | select(.name==$INFRA_CLUSTER_NAME).cluster.server')

touch ${RESTRICTED_INFRA_KUBECONFIG}

oc config set-cluster ${INFRA_CLUSTER_NAME} \
  --kubeconfig=${RESTRICTED_INFRA_KUBECONFIG} \
  --server=${INFRA_CLUSTER_API} \
  --certificate-authority=/tmp/ca.crt \
  --embed-certs=true

oc config set-credentials ${SA_NAME} \
  --kubeconfig=${RESTRICTED_INFRA_KUBECONFIG} \
  --token=${TOKEN}

oc config set-context ${INFRA_CLUSTER_NAME} \
  --kubeconfig=${RESTRICTED_INFRA_KUBECONFIG} \
  --user=${SA_NAME} \
  --cluster=${INFRA_CLUSTER_NAME}

oc config use-context ${INFRA_CLUSTER_NAME} --kubeconfig=${RESTRICTED_INFRA_KUBECONFIG}


# Create Role for VirtualMachines, VirtualMachineInstances, DataVolumes, Services and Routes
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
EOF

# Bind this role with the service account
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


