#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# NFS_PROVISIONER_IMAGE is set via the step registry env var (ref.yaml).
NFS_PROVISIONER_IMAGE="${NFS_PROVISIONER_IMAGE:-registry.k8s.io/sig-storage/nfs-provisioner:v4.0.8}"

echo "INFO: Step1: Create namespace nfs-provisioner."
oc create ns nfs-provisioner

oc label ns nfs-provisioner --overwrite \
  security.openshift.io/scc.podSecurityLabelSync=false \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged

echo "INFO: Step2: Deploy nfs-provisioner."
# This selects an uncordoned worker, not a guarantee of pod schedulability.
worker0=$(oc get nodes -l node-role.kubernetes.io/worker --field-selector spec.unschedulable=false \
  -o jsonpath='{.items[0].metadata.labels.kubernetes\.io/hostname}')
if [ -z "${worker0}" ]; then
  echo "ERROR: No worker hostname found for nfs-provisioner."
  exit 1
fi
oc annotate ns nfs-provisioner "scheduler.alpha.kubernetes.io/node-selector=kubernetes.io/hostname=${worker0}" --overwrite

echo "INFO: Creating service account."
oc -n nfs-provisioner create -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-provisioner
EOF

echo "INFO: Creating SecurityContextConstraints."
oc apply -f - <<EOF
allowHostDirVolumePlugin: true
allowHostIPC: false
allowHostNetwork: false
allowHostPID: false
allowHostPorts: false
allowPrivilegedContainer: false
allowedCapabilities:
- DAC_READ_SEARCH
- SYS_RESOURCE
apiVersion: security.openshift.io/v1
defaultAddCapabilities: null
fsGroup:
  type: MustRunAs
kind: SecurityContextConstraints
metadata:
  annotations: null
  name: nfs-provisioner
priority: null
readOnlyRootFilesystem: false
requiredDropCapabilities:
- KILL
- MKNOD
- SYS_CHROOT
runAsUser:
  type: RunAsAny
seLinuxContext:
  type: MustRunAs
supplementalGroups:
  type: RunAsAny
volumes:
- configMap
- downwardAPI
- emptyDir
- hostPath
- persistentVolumeClaim
- secret
EOF

echo "INFO: Creating RBAC resources."
oc -n nfs-provisioner apply -f - <<EOF
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: nfs-provisioner-runner
rules:
- apiGroups: [""]
  resources: ["persistentvolumes"]
  verbs: ["get", "list", "watch", "create", "delete"]
- apiGroups: [""]
  resources: ["persistentvolumeclaims"]
  verbs: ["get", "list", "watch", "update"]
- apiGroups: ["storage.k8s.io"]
  resources: ["storageclasses"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["events"]
  verbs: ["create", "update", "patch"]
- apiGroups: [""]
  resources: ["services", "endpoints"]
  verbs: ["get"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: run-nfs-provisioner
subjects:
- kind: ServiceAccount
  name: nfs-provisioner
  namespace: nfs-provisioner
roleRef:
  kind: ClusterRole
  name: nfs-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-provisioner
rules:
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-provisioner
subjects:
- kind: ServiceAccount
  name: nfs-provisioner
  namespace: nfs-provisioner
roleRef:
  kind: Role
  name: leader-locking-nfs-provisioner
  apiGroup: rbac.authorization.k8s.io
EOF

# Retained from the existing design. Least-privilege review remains pending.
echo "INFO: Configuring SCC access."
oc adm policy add-scc-to-user nfs-provisioner system:serviceaccount:nfs-provisioner:nfs-provisioner
oc adm policy add-scc-to-user privileged system:serviceaccount:nfs-provisioner:nfs-provisioner

echo "INFO: Creating service and deployment."
oc -n nfs-provisioner create -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nfs-provisioner
  labels:
    app: nfs-provisioner
spec:
  ports:
  - name: nfs
    port: 2049
  - name: nfs-udp
    port: 2049
    protocol: UDP
  - name: nlockmgr
    port: 32803
  - name: nlockmgr-udp
    port: 32803
    protocol: UDP
  - name: mountd
    port: 20048
  - name: mountd-udp
    port: 20048
    protocol: UDP
  - name: rquotad
    port: 875
  - name: rquotad-udp
    port: 875
    protocol: UDP
  - name: rpcbind
    port: 111
  - name: rpcbind-udp
    port: 111
    protocol: UDP
  - name: statd
    port: 662
  - name: statd-udp
    port: 662
    protocol: UDP
  selector:
    app: nfs-provisioner
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-provisioner
spec:
  selector:
    matchLabels:
      app: nfs-provisioner
  replicas: 1
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: nfs-provisioner
    spec:
      serviceAccount: nfs-provisioner
      initContainers:
      - name: init
        image: ${NFS_PROVISIONER_IMAGE}
        command:
        - sh
        - "-c"
        - mkdir -p /var/lib/nfs-provisioner && chcon -Rt svirt_sandbox_file_t /var/lib/nfs-provisioner && chmod 777 /var/lib/nfs-provisioner
        volumeMounts:
        - mountPath: "/var/lib"
          name: local
        securityContext:
          privileged: true
      containers:
      - name: nfs-provisioner
        image: ${NFS_PROVISIONER_IMAGE}
        ports:
        - name: nfs
          containerPort: 2049
        - name: nfs-udp
          containerPort: 2049
          protocol: UDP
        - name: nlockmgr
          containerPort: 32803
        - name: nlockmgr-udp
          containerPort: 32803
          protocol: UDP
        - name: mountd
          containerPort: 20048
        - name: mountd-udp
          containerPort: 20048
          protocol: UDP
        - name: rquotad
          containerPort: 875
        - name: rquotad-udp
          containerPort: 875
          protocol: UDP
        - name: rpcbind
          containerPort: 111
        - name: rpcbind-udp
          containerPort: 111
          protocol: UDP
        - name: statd
          containerPort: 662
        - name: statd-udp
          containerPort: 662
          protocol: UDP
        securityContext:
          capabilities:
            add:
            - DAC_READ_SEARCH
            - SYS_RESOURCE
        readinessProbe:
          tcpSocket:
            port: 2049
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 2049
          initialDelaySeconds: 15
          periodSeconds: 20
        args:
        - "-provisioner=example.com/nfs"
        env:
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: SERVICE_NAME
          value: nfs-provisioner
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        imagePullPolicy: "IfNotPresent"
        volumeMounts:
        - name: export-volume
          mountPath: /export
      volumes:
      - name: export-volume
        hostPath:
          path: /var/lib/nfs-provisioner
      - name: local
        hostPath:
          path: "/var/lib"
EOF

if ! oc -n nfs-provisioner rollout status deployment/nfs-provisioner --timeout=300s; then
  echo "ERROR: NFS provisioner rollout check failed (timeout limit: 300 seconds)."
  exit 1
fi

echo "INFO: Step3: Create StorageClass nfs."
oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs
provisioner: example.com/nfs
mountOptions:
- vers=4.1
- hard
- intr
EOF

echo "INFO: Step4: Set nfs as default only when no default StorageClass exists."
default_sc_annotations="$(oc get storageclass -o jsonpath='{range .items[*]}{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}{"\n"}{end}')"
if ! grep -qx 'true' <<< "${default_sc_annotations}"; then
  oc patch storageclass nfs -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
fi

echo "INFO: NFS deployment and StorageClass setup completed."
