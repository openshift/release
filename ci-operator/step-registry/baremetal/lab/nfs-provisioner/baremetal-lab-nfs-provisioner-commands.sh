#!/bin/bash

set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# In a network restricted environment additional images required by the nfs provisioner cannot be pulled from the internet,
# thus the need to have it mirrored and accessible through the proxy registry hosted on the aux host.
# Associated PR at https://gitlab.cee.redhat.com/aosqe/tests-images/-/merge_requests/85
NFS_CLIENT_MIRRORED_IMAGE_URL="quay.io/openshifttest/nfs-subdir-external-provisioner@sha256:3036bf6b741cdee4caf8fc30bccd049afdf662e08a52f2e6ae47b75ef52a40ac"


# Set the NFS_SERVER value to the same value as the AUX_HOST, unless explicitly set.
NFS_SERVER=${NFS_SERVER:-$(<"${CLUSTER_PROFILE_DIR}/aux-host-internal-name")}
DIR=/tmp/nfs-provisioner
CLUSTER_NAME=$(<"${SHARED_DIR}/cluster_name")
mkdir -p ${DIR}

cat > ${DIR}/00-namespace.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: nfs-provisioner

EOF

cat > ${DIR}/01-rbac.yaml <<EOF
kind: List
apiVersion: v1
items:
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    metadata:
      name: system:openshift:scc:hostmount-anyuid
    rules:
      - apiGroups:
          - security.openshift.io
        resourceNames:
          - hostmount-anyuid
        resources:
          - securitycontextconstraints
        verbs:
          - use
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRoleBinding
    metadata:
      name: system:openshift:scc:hostmount-anyuid
    roleRef:
      apiGroup: rbac.authorization.k8s.io
      kind: ClusterRole
      name: system:openshift:scc:hostmount-anyuid
    subjects:
      - kind: ServiceAccount
        name: nfs-client-provisioner
        namespace: nfs-provisioner

EOF

cat > ${DIR}/10-deployment-patch.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: nfs-client-provisioner
  name: nfs-client-provisioner
spec:
  template:
    spec:
      containers:
        - name: nfs-client-provisioner
          image: ${NFS_CLIENT_MIRRORED_IMAGE_URL}
          env:
            - name: NFS_SERVER
              value: ${NFS_SERVER}
            - name: NFS_PATH
              value: /opt/nfs/${CLUSTER_NAME}
      volumes:
        - name: nfs-client-root
          nfs:
            server: ${NFS_SERVER}
            path: /opt/nfs/${CLUSTER_NAME}

EOF

cat > ${DIR}/15-default-storage-class-patch.yaml <<EOF
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: nfs-client
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"

EOF

cat > ${DIR}/kustomization.yaml <<EOF
namespace: nfs-provisioner

resources:
  - 00-namespace.yaml
  - 01-rbac.yaml
  - github.com/kubernetes-sigs/nfs-subdir-external-provisioner//deploy

patchesStrategicMerge:
  - 10-deployment-patch.yaml
  - 15-default-storage-class-patch.yaml

EOF

echo "Deploying the nfs-provisioner with the following payloads:"
more ${DIR}/*.yaml | cat

echo
oc apply -k ${DIR}
echo "Waiting up to 10 minutes for the nfs-provisioner pod to become ready..."
for _ in $(seq 1 10); do
  sleep 60
  if oc -n nfs-provisioner get pods --no-headers -l app=nfs-client-provisioner | grep -q -w Running; then
    echo "The nfs-provisioner pod is ready. Continuing..."
    exit 0
  fi
done
echo "Timeout reached while waiting for the nfs-provisioner pod to become ready. Failing..."
exit 1
