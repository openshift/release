#!/bin/bash

namespace="openshift-debug"
podname="oslat"

echo "Setting up cluster configuration for test"
oc apply -f - <<EOF
kind: Project
apiVersion: project.openshift.io/v1
metadata:
  name: openshift-debug
  labels:
    kubernetes.io/metadata.name: debug
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
  annotations:
    workload.openshift.io/allowed: management
    openshift.io/node-selector: ""
spec: {}

---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: debug
  namespace: ${namespace}

---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:openshift:scc:privileged
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:openshift:scc:privileged
subjects:
  - kind: ServiceAccount
    name: debug
    namespace: ${namespace}

---
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: oslat
  name: ${podname}
  namespace: ${namespace}
spec:
  containers:
    - image: quay.io/ocp-edge-qe/oslat
      imagePullPolicy: Always
      name: container-00
      command: ["sh"]
      args:
        - "-c"
        - "sleep 5000"
      resources: {}
      securityContext:
        privileged: true
  dnsPolicy: ClusterFirst
  serviceAccount: debug
  serviceAccountName: debug
  terminationGracePeriodSeconds: 30
EOF

echo "waiting for pod/${podname} to be ready"
oc wait --for=condition=Ready pod/$podname --timeout=30s -n $namespace

echo "executing the os latency test"
oc exec $podname -n $namespace -- oslat -D 5m

echo "cleaning up the pod"
oc delete pod $podname