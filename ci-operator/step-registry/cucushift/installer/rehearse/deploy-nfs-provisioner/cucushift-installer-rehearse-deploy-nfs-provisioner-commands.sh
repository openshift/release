#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# NFS_PROVISIONER_IMAGE is set via the step registry env var (ref.yaml)
NFS_PROVISIONER_IMAGE="${NFS_PROVISIONER_IMAGE:-registry.k8s.io/sig-storage/nfs-provisioner:v4.0.8}"

echo "INFO: Using NFS provisioner image: ${NFS_PROVISIONER_IMAGE}"
echo "INFO: Start to deploy nfs-provisioner."
echo "INFO: Step1: Create namespace nfs-provisioner."
oc create ns nfs-provisioner

echo "Label namespace to allow privileged pods (required for NFS provisioner)"
oc label ns nfs-provisioner --overwrite \
  security.openshift.io/scc.podSecurityLabelSync=false \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged

echo "INFO: Step2: Deploy nfs-provisioner."
worker0=$(oc get nodes --show-labels |grep worker|grep -v SchedulingDisabled|awk '{print $6}'|head -1|awk -F ',' '{ORS="\n"; for(i=1;i<=NF;i++) print $i}' | grep hostname | awk -F '=' '{print $NF}')
oc annotate ns nfs-provisioner scheduler.alpha.kubernetes.io/node-selector=kubernetes.io/hostname="${worker0}" --overwrite

# --- Step 2a: Create ServiceAccount first (needed for SCC binding) ---
echo "Creating service account"
oc -n nfs-provisioner create -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-provisioner
EOF

echo "Creating SecurityContextConstraints"
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

echo "Creating ClusterRole, ClusterRoleBinding, Role"
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
  - apiGroups: ["extensions"]
    resources: ["podsecuritypolicies"]
    resourceNames: ["nfs-provisioner"]
    verbs: ["use"]
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

echo "Creating policy"
oc adm policy add-scc-to-user nfs-provisioner system:serviceaccount:nfs-provisioner:nfs-provisioner
oc adm policy add-scc-to-user privileged system:serviceaccount:nfs-provisioner:nfs-provisioner

echo "Creating service and deployment"
oc -n nfs-provisioner create -f - <<EOF
---
kind: Service
apiVersion: v1
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
kind: Deployment
apiVersion: apps/v1
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
        - mkdir -p /var/lib/nfs-provisioner;chcon -Rt svirt_sandbox_file_t /var/lib/nfs-provisioner;chmod 777 /var/lib/nfs-provisioner
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

echo "Creating SecurityContextConstraints"
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

echo "Creating ClusterRole, ClusterRoleBinding, Role"
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
  - apiGroups: ["extensions"]
    resources: ["podsecuritypolicies"]
    resourceNames: ["nfs-provisioner"]
    verbs: ["use"]
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

echo "Creating policy"
oc adm policy add-scc-to-user nfs-provisioner system:serviceaccount:nfs-provisioner:nfs-provisioner
oc adm policy add-scc-to-user privileged system:serviceaccount:nfs-provisioner:nfs-provisioner

i=0
period=10
while true; do
  POD_STATUS="$(oc -n nfs-provisioner get pods -l "app=nfs-provisioner" -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' || true)"
  if grep -q '^Running$' <<<"$POD_STATUS"; then
        break;
  fi
  sleep $period
  i=$((i + period))
  if [ "$i" -ge 300 ]; then
    echo "ERROR: Step2: Deploy nfs-provisioner failed, exit."
    echo "INFO: Print event in nfs-provisioner namespace"
    oc -n nfs-provisioner get event
    exit 1
  fi
done

echo "INFO: Step2: Deploy nfs-provisioner successfully."

echo "INFO: Step3: Create storage class nfs."
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

echo "INFO: Step4: Set storageclass nfs as default storageclass if there is no default one......"
sc_out="$(oc get storageclass --no-headers 2>/dev/null || true)"
default_sc_count="$(grep -c 'default' <<<"$sc_out" || true)"
if [ "${default_sc_count}" -eq 0 ]; then
  oc patch storageclass nfs -p '{"metadata": {"annotations": {"storageclass.kubernetes.io/is-default-class": "true"}}}'
fi

echo "INFO: Deploy nfs-provisioner successfully."

echo "INFO: Print existing storageclass."
echo "=================================="
oc get sc