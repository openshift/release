#!/bin/bash

#!/bin/bash

namespace="openshift-debug"
jobname="oslat"

echo "setting up cluster and job configuration for the test"
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
apiVersion: batch/v1
kind: Job
metadata:
  labels:
    app: oslat
  name: ${jobname}
  namespace: ${namespace}
spec:
  parallelism: 1
  completions: 1
  activeDeadlineSeconds: 360
  backoffLimit: 5
  template:
    metadata:
      name: ${jobname}
    spec:
      containers:
      - image: quay.io/ocp-edge-qe/oslat
        imagePullPolicy: Always
        name: container-00
        command: ["oslat", "-D 5m"]
        securityContext:
          privileged: true
      restartPolicy: OnFailure
      resources: {}
      dnsPolicy: ClusterFirst
      serviceAccount: debug
      serviceAccountName: debug
      terminationGracePeriodSeconds: 30
EOF

echo "waiting for job/${jobname} to complete"
oc wait --for=condition=complete job/$jobname --timeout=60m -n $namespace

echo "getting job output"
jlog=$(oc logs job/${jobname})

echo "${jlog}"

# Cleanup
oc delete job $jobname