#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail



cp -L $KUBECONFIG /tmp/kubeconfig

export KUBECONFIG=/tmp/kubeconfig

oc create -f - <<EOF
        apiVersion: cluster.open-cluster-management.io/v1beta2
        kind: ManagedClusterSet
        metadata:
          name: managed-cluster-set
        spec: {}

EOF
 
oc create -f - <<EOF
        apiVersion: cluster.open-cluster-management.io/v1beta2
        kind: ManagedClusterSetBinding
        metadata:
          name: managed-cluster-set
          namespace: ocm
        spec:
          clusterSet: managed-cluster-set
EOF


oc label managedcluster local-cluster cluster.open-cluster-management.io/clusterset=managed-cluster-set --overwrite

# oc create -f - <<EOF
#         apiVersion: policy.open-cluster-management.io/v1
#         kind: Policy
#         metadata:
#           name: cnv-install
#           namespace: openshift-cnv
#           annotations:
#             policy.open-cluster-management.io/categories: ""
#             policy.open-cluster-management.io/standards: ""
#             policy.open-cluster-management.io/controls: ""
#         spec:
#           disabled: false
#           remediationAction: enforce
#           policy-templates:
#             - objectDefinition:
#                 apiVersion: policy.open-cluster-management.io/v1beta1
#                 kind: OperatorPolicy
#                 metadata:
#                   name: install-cnv-operator
#                 spec:
#                   remediationAction: enforce
#                   severity: critical
#                   complianceType: musthave
#                   subscription:
#                     name: kubevirt-hyperconverged
#                     namespace: openshift-cnv
#                     channel: stable
#                     source: redhat-operators
#                     sourceNamespace: openshift-marketplace
#                   upgradeApproval: Automatic
#                   versions:
#                   operatorGroup:
#                     name: default
#                     targetNamespaces:
#                       - openshift-cnv
#         ---
#         apiVersion: cluster.open-cluster-management.io/v1beta1
#         kind: Placement
#         metadata:
#           name: cnv-install-placement
#           namespace: openshift-cnv
#         spec:
#           tolerations:
#             - key: cluster.open-cluster-management.io/unreachable
#               operator: Exists
#             - key: cluster.open-cluster-management.io/unavailable
#               operator: Exists
#           clusterSets:
#             - test-cluster-set
#         ---
#         apiVersion: policy.open-cluster-management.io/v1
#         kind: PlacementBinding
#         metadata:
#           name: cnv-install-placement
#           namespace: openshift-cnv
#         placementRef:
#           name: cnv-install-placement
#           apiGroup: cluster.open-cluster-management.io
#           kind: Placement
#         subjects:
#           - name: cnv-install
#             apiGroup: policy.open-cluster-management.io
#             kind: Policy
# EOF

# oc wait hyperconverged -n openshift-cnv kubevirt-hyperconverged --for=condition=Available --timeout=20m

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"

if [[ -f "${AWSCRED}" ]]; then

  AWS_ACCESS_KEY_ID=$(cat "${AWSCRED}" | grep aws_access_key_id | tr -d ' ' | cut -d '=' -f 2)
  AWS_SECRET_ACCESS_KEY=$(cat "${AWSCRED}" | grep aws_secret_access_key | tr -d ' ' | cut -d '=' -f 2)

  oc create -f - <<EOF
          apiVersion: v1
          kind: Secret
          metadata:
            name: aws-creds
            namespace: ocm
            labels:
               hive.openshift.io/secret-type: aws
          type: Opaque
          stringData:
            aws_access_key_id: "${AWS_ACCESS_KEY_ID}"
            aws_secret_access_key: "${AWS_SECRET_ACCESS_KEY}"
EOF

  echo "secret created"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi


PULL_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/cloud-openshift-auth")
if [[ -f "${PULL_SECRET}" ]]; then

  oc create -f - <<EOF
          apiVersion: v1
          kind: Secret
          metadata:
            name: pull-secret
            namespace: ocm
          type: kubernetes.io/dockerconfigjson
          data:
            .dockerconfigjson: "${PULL_SECRET}"
EOF

  echo "secret created"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi
           