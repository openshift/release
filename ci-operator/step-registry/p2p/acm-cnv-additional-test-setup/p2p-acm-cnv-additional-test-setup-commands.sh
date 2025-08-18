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


OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
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
           