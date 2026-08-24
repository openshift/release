#!/usr/bin/env bash
# Deploy an in-cluster NFS dynamic provisioner for SBR unknown-provisioner
# tests. StorageClass "nfs-sbr-dynamic" uses provisioner "sbr.io/nfs-provisioner"
# with reclaimPolicy Retain — SBR treats this as an unknown provisioner and
# triggers its testRWXSupport code path.
set -euo pipefail

NS="nfs-sbr-provisioner"
PROVISIONER_NAME="sbr.io/nfs-provisioner"
SC_NAME="nfs-sbr-dynamic"
NFS_IMAGE="quay.io/openshifttest/nfs-provisioner@sha256:f402e6039b3c1e60bf6596d283f3c470ffb0a1e169ceb8ce825e3218cd66c050"

echo "INFO: Creating namespace ${NS}"
oc create ns "${NS}"

oc label ns "${NS}" --overwrite \
  security.openshift.io/scc.podSecurityLabelSync=false \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged

echo "INFO: Creating RBAC resources"
oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-provisioner
  namespace: ${NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nfs-sbr-provisioner-runner
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
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: run-nfs-sbr-provisioner
subjects:
- kind: ServiceAccount
  name: nfs-provisioner
  namespace: ${NS}
roleRef:
  kind: ClusterRole
  name: nfs-sbr-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: leader-locking-nfs-provisioner
  namespace: ${NS}
rules:
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["get", "list", "watch", "create", "update", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: leader-locking-nfs-provisioner
  namespace: ${NS}
subjects:
- kind: ServiceAccount
  name: nfs-provisioner
  namespace: ${NS}
roleRef:
  kind: Role
  name: leader-locking-nfs-provisioner
  apiGroup: rbac.authorization.k8s.io
EOF

echo "INFO: Creating SecurityContextConstraints"
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
  name: nfs-sbr-provisioner
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
- persistentVolumeClaim
- secret
- hostPath
EOF

oc adm policy add-scc-to-user nfs-sbr-provisioner "system:serviceaccount:${NS}:nfs-provisioner"
oc adm policy add-scc-to-user privileged "system:serviceaccount:${NS}:nfs-provisioner"

echo "INFO: Creating Service and Deployment"
oc -n "${NS}" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nfs-provisioner
  labels:
    app: nfs-sbr-provisioner
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
    app: nfs-sbr-provisioner
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-provisioner
spec:
  selector:
    matchLabels:
      app: nfs-sbr-provisioner
  replicas: 1
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: nfs-sbr-provisioner
    spec:
      serviceAccount: nfs-provisioner
      initContainers:
      - name: init
        image: ${NFS_IMAGE}
        command: ["sh", "-c", "mkdir -p /srv/nfs; chcon -Rt svirt_sandbox_file_t /srv/nfs 2>/dev/null || true; chmod 777 /srv/nfs"]
        volumeMounts:
        - mountPath: /srv
          name: local
        securityContext:
          privileged: true
      containers:
      - name: nfs-provisioner
        image: ${NFS_IMAGE}
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
        args:
        - "-provisioner=${PROVISIONER_NAME}"
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
        imagePullPolicy: IfNotPresent
        volumeMounts:
        - name: export-volume
          mountPath: /export
      volumes:
      - name: export-volume
        hostPath:
          path: /srv/nfs
      - name: local
        hostPath:
          path: /srv
EOF

echo "INFO: Waiting for NFS provisioner pod to be Running"
elapsed=0
while [ "${elapsed}" -lt 300 ]; do
  phase=$(oc -n "${NS}" get pods -l "app=nfs-sbr-provisioner" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Pending")
  if [ "${phase}" = "Running" ]; then
    echo "INFO: NFS provisioner pod is Running"
    break
  fi
  echo "INFO: Pod phase=${phase}, waiting..."
  sleep 10
  elapsed=$((elapsed + 10))
done

if [ "${elapsed}" -ge 300 ]; then
  echo "ERROR: NFS provisioner pod did not reach Running within 5 minutes"
  oc -n "${NS}" get pods -o wide
  oc -n "${NS}" get events --sort-by='.lastTimestamp'
  exit 1
fi

echo "INFO: Creating StorageClass ${SC_NAME}"
oc apply -f - <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${SC_NAME}
provisioner: ${PROVISIONER_NAME}
reclaimPolicy: Retain
mountOptions:
- vers=4.1
EOF

echo "INFO: NFS dynamic provisioner deployed successfully"
oc get sc "${SC_NAME}"
oc -n "${NS}" get pods
