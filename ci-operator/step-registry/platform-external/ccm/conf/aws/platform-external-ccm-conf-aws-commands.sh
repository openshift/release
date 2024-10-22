#!/bin/bash

#
# Create AWS CCM manifests.
#

set -o nounset
set -o errexit
set -o pipefail

source "${SHARED_DIR}/init-fn.sh" || true
test -f "${SHARED_DIR}/infra_resources.env" && source "${SHARED_DIR}/infra_resources.env"

# Proceed only when CCM is should be deployed.
if [[ "${PLATFORM_EXTERNAL_CCM_ENABLED-}" != "yes" ]]; then
  log "Ignoring CCM Installation setup. PLATFORM_EXTERNAL_CCM_ENABLED!=yes [${PLATFORM_EXTERNAL_CCM_ENABLED}]"
  exit 0
fi

#
# Setup CCM deployment manifests
#

# Discovering the AWS CCM image from OpenShift release payload.
log "Discovering controller image 'aws-cloud-controller-manager' from release [${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE-}]"

# tmp forcing to use in this step a different path.
REGISTRY_AUTH_FILE=/tmp/secret/pull-secret-with-ci

CCM_IMAGE="$(oc adm release info -a "${REGISTRY_AUTH_FILE}" "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" --image-for='aws-cloud-controller-manager')"
CCM_MANIFEST=ccm-00-deployment.yaml
CCM_MANIFEST_PATH="${SHARED_DIR}"/${CCM_MANIFEST}

log "Using CCM image=${CCM_IMAGE}"

log "Creating CloudController Manager deployment"

# TODO/FixMe(mtulio): create RBAC according to the upstream project (CCM) requirement.
# Currently it is using openshift-cloud-controller-manager (cluster defaults):
cat << EOF > "$CCM_MANIFEST_PATH"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    k8s-app: aws-cloud-controller-manager
    infrastructure.openshift.io/cloud-controller-manager: aws
  name: aws-cloud-controller-manager
  namespace: ${CCM_NAMESPACE}
spec:
  replicas: 2
  selector:
    matchLabels:
      k8s-app: aws-cloud-controller-manager
      infrastructure.openshift.io/cloud-controller-manager: aws
  strategy:
    type: Recreate
  template:
    metadata:
      annotations:
        target.workload.openshift.io/management: '{"effect": "PreferredDuringScheduling"}'
      labels:
        k8s-app: aws-cloud-controller-manager
        infrastructure.openshift.io/cloud-controller-manager: aws
    spec:
      priorityClassName: system-cluster-critical
      containers:
      - command:
        - /bin/bash
        - -c
        - |
          #!/bin/bash
          set -o allexport
          if [[ -f /etc/kubernetes/apiserver-url.env ]]; then
            source /etc/kubernetes/apiserver-url.env
          fi
          exec /bin/aws-cloud-controller-manager \
          --cloud-provider=aws \
          --use-service-account-credentials=true \
          --configure-cloud-routes=false \
          --leader-elect=true \
          --leader-elect-lease-duration=137s \
          --leader-elect-renew-deadline=107s \
          --leader-elect-retry-period=26s \
          --leader-elect-resource-namespace=${CCM_NAMESPACE} \
          -v=2
        image: ${CCM_IMAGE}
        imagePullPolicy: IfNotPresent
        name: cloud-controller-manager
        ports:
        - containerPort: 10258
          name: https
          protocol: TCP
        resources:
          requests:
            cpu: 200m
            memory: 50Mi
        volumeMounts:
        - mountPath: /etc/kubernetes
          name: host-etc-kube
          readOnly: true
        - name: trusted-ca
          mountPath: /etc/pki/ca-trust/extracted/pem
          readOnly: true
      hostNetwork: true
      nodeSelector:
        node-role.kubernetes.io/master: ""
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - topologyKey: "kubernetes.io/hostname"
            labelSelector:
              matchLabels:
                k8s-app: aws-cloud-controller-manager
                infrastructure.openshift.io/cloud-controller-manager: aws
      serviceAccountName: cloud-controller-manager
      tolerations:
      - effect: NoSchedule
        key: node-role.kubernetes.io/master
        operator: Exists
      - effect: NoExecute
        key: node.kubernetes.io/unreachable
        operator: Exists
        tolerationSeconds: 120
      - effect: NoExecute
        key: node.kubernetes.io/not-ready
        operator: Exists
        tolerationSeconds: 120
      - effect: NoSchedule
        key: node.cloudprovider.kubernetes.io/uninitialized
        operator: Exists
      - effect: NoSchedule
        key: node.kubernetes.io/not-ready
        operator: Exists
      volumes:
      - name: trusted-ca
        configMap:
          name: ccm-trusted-ca
          items:
            - key: ca-bundle.crt
              path: tls-ca-bundle.pem
      - name: host-etc-kube
        hostPath:
          path: /etc/kubernetes
          type: Directory
EOF

# TODO(mtulio): assert the correct RBAC to create namespace and permissions required
# to run AWS CCM without inheriting from the default integration.

# cat << EOF > "$CCM_MANIFEST_PATH"
# ---
# apiVersion: v1
# kind: Namespace
# metadata:
#   name: ${CCM_NAMESPACE}
#   annotations:
#     workload.openshift.io/allowed: management
#   labels:
#     "pod-security.kubernetes.io/enforce": "privileged"
#     "pod-security.kubernetes.io/audit": "privileged"
#     "pod-security.kubernetes.io/warn": "privileged"
#     "security.openshift.io/scc.podSecurityLabelSync": "false"
#     "openshift.io/run-level": "0"
#     "pod-security.kubernetes.io/enforce-version": "v1.24"
# ---
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: ${CCM_NAMESPACE}
#   namespace: ${CCM_NAMESPACE}
# ---
# apiVersion: rbac.authorization.k8s.io/v1
# kind: ClusterRole
# metadata:
#   name: ${CCM_NAMESPACE}
# rules:
# - apiGroups:
#   - ""
#   resources:
#   - nodes
#   - services
#   verbs:
#   - get
#   - list
#   - watch
# - apiGroups:
#   - ""
#   resources:
#   - events
#   verbs:
#   - create
#   - patch
# ---
# apiVersion: rbac.authorization.k8s.io/v1
# kind: ClusterRoleBinding
# metadata:
#   name: ${CCM_NAMESPACE}
# roleRef:
#   apiGroup: rbac.authorization.k8s.io
#   kind: ClusterRole
#   name: system:${CCM_NAMESPACE}
# subjects:
# - kind: ServiceAccount
#   name: ${CCM_NAMESPACE}
#   namespace: ${CCM_NAMESPACE}
# ---
# apiVersion: apps/v1
# kind: Deployment
# metadata:
#   labels:
#     k8s-app: aws-cloud-controller-manager
#     infrastructure.openshift.io/cloud-controller-manager: aws
#   name: aws-cloud-controller-manager
#   namespace: ${CCM_NAMESPACE}
# spec:
#   replicas: 2
#   selector:
#     matchLabels:
#       k8s-app: aws-cloud-controller-manager
#       infrastructure.openshift.io/cloud-controller-manager: aws
#   strategy:
#     type: Recreate
#   template:
#     metadata:
#       annotations:
#         target.workload.openshift.io/management: '{"effect": "PreferredDuringScheduling"}'
#       labels:
#         k8s-app: aws-cloud-controller-manager
#         infrastructure.openshift.io/cloud-controller-manager: aws
#     spec:
#       priorityClassName: system-cluster-critical
#       containers:
#       - command:
#         - /bin/bash
#         - -c
#         - |
#           #!/bin/bash
#           set -o allexport
#           if [[ -f /etc/kubernetes/apiserver-url.env ]]; then
#             source /etc/kubernetes/apiserver-url.env
#           fi
#           exec /bin/aws-cloud-controller-manager \
#           --cloud-provider=aws \
#           --use-service-account-credentials=true \
#           --configure-cloud-routes=false \
#           --leader-elect=true \
#           --leader-elect-lease-duration=137s \
#           --leader-elect-renew-deadline=107s \
#           --leader-elect-retry-period=26s \
#           --leader-elect-resource-namespace=${CCM_NAMESPACE} \
#           -v=2
#         image: ${CCM_IMAGE}
#         imagePullPolicy: IfNotPresent
#         name: cloud-controller-manager
#         ports:
#         - containerPort: 10258
#           name: https
#           protocol: TCP
#         resources:
#           requests:
#             cpu: 200m
#             memory: 50Mi
#         volumeMounts:
#         - mountPath: /etc/kubernetes
#           name: host-etc-kube
#           readOnly: true
#         - name: trusted-ca
#           mountPath: /etc/pki/ca-trust/extracted/pem
#           readOnly: true
#       hostNetwork: true
#       nodeSelector:
#         node-role.kubernetes.io/master: ""
#       affinity:
#         podAntiAffinity:
#           requiredDuringSchedulingIgnoredDuringExecution:
#           - topologyKey: "kubernetes.io/hostname"
#             labelSelector:
#               matchLabels:
#                 k8s-app: aws-cloud-controller-manager
#                 infrastructure.openshift.io/cloud-controller-manager: aws
#       serviceAccountName: external-cloud-controller-manager
#       tolerations:
#       - effect: NoSchedule
#         key: node-role.kubernetes.io/master
#         operator: Exists
#       - effect: NoExecute
#         key: node.kubernetes.io/unreachable
#         operator: Exists
#         tolerationSeconds: 120
#       - effect: NoExecute
#         key: node.kubernetes.io/not-ready
#         operator: Exists
#         tolerationSeconds: 120
#       - effect: NoSchedule
#         key: node.cloudprovider.kubernetes.io/uninitialized
#         operator: Exists
#       - effect: NoSchedule
#         key: node.kubernetes.io/not-ready
#         operator: Exists
#       volumes:
#       - name: trusted-ca
#         configMap:
#           name: ccm-trusted-ca
#           items:
#             - key: ca-bundle.crt
#               path: tls-ca-bundle.pem
#       - name: host-etc-kube
#         hostPath:
#           path: /etc/kubernetes
#           type: Directory
# EOF

log "Created!"
echo "$CCM_MANIFEST" >> ${SHARED_DIR}/ccm-manifests.txt
echo "CCM_STATUS_KEY=.status.availableReplicas" >> "${SHARED_DIR}/deploy.env"
cp -v "${SHARED_DIR}/ccm-manifests.txt" "${ARTIFACT_DIR}/"

cat << EOF > "${SHARED_DIR}/ccm.env"
CCM_RESOURCE="Deployment/aws-cloud-controller-manager"
CCM_NAMESPACE=${CCM_NAMESPACE}
CCM_REPLICAS_COUNT=2
EOF
