#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

VSPHERECCM="${SHARED_DIR}/vsphere-cloud-controller-manager.yaml"
source "${SHARED_DIR}/govc.sh"

cat > "${VSPHERECCM}" << EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloud-controller-manager
  labels:
    vsphere-cpi-infra: service-account
    component: cloud-controller-manager
  namespace: kube-system
---
apiVersion: v1
kind: Secret
metadata:
  name: vsphere-cloud-secret
  labels:
    vsphere-cpi-infra: secret
    component: cloud-controller-manager
  namespace: kube-system
  # NOTE: this is just an example configuration, update with real values based on your environment
stringData:
  ${GOVC_URL}.username: "${GOVC_USERNAME}"
  ${GOVC_URL}.password: "${GOVC_PASSWORD}"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vsphere-cloud-config
  labels:
    vsphere-cpi-infra: config
    component: cloud-controller-manager
  namespace: kube-system
data:
  # NOTE: this is just an example configuration, update with real values based on your environment
  vsphere.conf: |
    # Global properties in this section will be used for all specified vCenters unless overriden in VirtualCenter section.
    global:
      port: 443
      # set insecureFlag to true if the vCenter uses a self-signed cert
      insecureFlag: true
      # settings for using k8s secret
      secretName: vsphere-cloud-secret
      secretNamespace: kube-system
    # vcenter section
    vcenter:
      ${GOVC_URL}:
        server: ${GOVC_URL}
        datacenters:
          - ${GOVC_DATACENTER}
    # labels for regions and zones
    # labels:
    #  region: k8s-region
    #  zone: k8s-zone
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: servicecatalog.k8s.io:apiserver-authentication-reader
  labels:
    vsphere-cpi-infra: role-binding
    component: cloud-controller-manager
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
  - apiGroup: ""
    kind: ServiceAccount
    name: cloud-controller-manager
    namespace: kube-system
  - apiGroup: ""
    kind: User
    name: cloud-controller-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:cloud-controller-manager
  labels:
    vsphere-cpi-infra: cluster-role-binding
    component: cloud-controller-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:cloud-controller-manager
subjects:
  - kind: ServiceAccount
    name: cloud-controller-manager
    namespace: kube-system
  - kind: User
    name: cloud-controller-manager
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:cloud-controller-manager
  labels:
    vsphere-cpi-infra: role
    component: cloud-controller-manager
rules:
  - apiGroups:
      - ""
    resources:
      - events
    verbs:
      - create
      - patch
      - update
  - apiGroups:
      - ""
    resources:
      - nodes
    verbs:
      - "*"
  - apiGroups:
      - ""
    resources:
      - nodes/status
    verbs:
      - patch
  - apiGroups:
      - ""
    resources:
      - services
    verbs:
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - ""
    resources:
      - services/status
    verbs:
      - patch
  - apiGroups:
      - ""
    resources:
      - serviceaccounts
    verbs:
      - create
      - get
      - list
      - watch
      - update
  - apiGroups:
      - ""
    resources:
      - persistentvolumes
    verbs:
      - get
      - list
      - update
      - watch
  - apiGroups:
      - ""
    resources:
      - endpoints
    verbs:
      - create
      - get
      - list
      - watch
      - update
  - apiGroups:
      - ""
    resources:
      - secrets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - "coordination.k8s.io"
    resources:
      - leases
    verbs:
      - create
      - get
      - list
      - watch
      - update
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vsphere-cloud-controller-manager
  labels:
    component: cloud-controller-manager
    tier: control-plane
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: vsphere-cloud-controller-manager
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: vsphere-cloud-controller-manager
        component: cloud-controller-manager
        tier: control-plane
    spec:
      tolerations:
        - key: node.cloudprovider.kubernetes.io/uninitialized
          value: "true"
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          effect: NoSchedule
          operator: Exists
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
          operator: Exists
        - key: node.kubernetes.io/not-ready
          effect: NoSchedule
          operator: Exists
      securityContext:
        runAsUser: 1001
      serviceAccountName: cloud-controller-manager
      priorityClassName: system-node-critical
      containers:
        - name: vsphere-cloud-controller-manager
          image: gcr.io/cloud-provider-vsphere/cpi/release/manager:v1.27.0
          env:            
          - name: "KUBERNETES_SERVICE_HOST"
            value: "<kubernetes_service_host>"
          - name: "KUBERNETES_SERVICE_PORT"
            value: "6443"
          args:
            - --cloud-provider=vsphere
            - --v=2
            - --cloud-config=/etc/cloud/vsphere.conf
          volumeMounts:
            - mountPath: /etc/cloud
              name: vsphere-config-volume
              readOnly: true
          resources:
            requests:
              cpu: 200m
      hostNetwork: true
      volumes:
        - name: vsphere-config-volume
          configMap:
            name: vsphere-cloud-config
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
            - matchExpressions:
              - key: node-role.kubernetes.io/master
                operator: Exists
EOF