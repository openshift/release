#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

test -f "${SHARED_DIR}/infra_resources.env" && source "${SHARED_DIR}/infra_resources.env"


if [[ "${PLATFORM_EXTERNAL_CCM_ENABLED-}" != "yes" ]]; then
  echo_date "Ignoring CCM Installation setup. PLATFORM_EXTERNAL_CCM_ENABLED!=yes [${PLATFORM_EXTERNAL_CCM_ENABLED}]"
  exit 0
fi

# Build from: https://github.com/openshift/cloud-provider-aws/blob/master/Dockerfile.openshift
#CCM_IMAGE="quay.io/mrbraga/openshift-cloud-provider-aws:latest"
CCM_IMAGE="$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" --image-for='aws-cloud-controller-manager')"
CCM_NAMESPACE=openshift-cloud-controller-manager
CCM_MANIFEST=ccm-00-deployment.yaml
CCM_MANIFEST_PATH="${SHARED_DIR}"/${CCM_MANIFEST}

echo "Using CCM image=${CCM_IMAGE}"

echo_date "Creating CloudController Manager deployment"

cat << EOF | envsubst > $CCM_MANIFEST_PATH
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


echo_date "Created!"
echo "$CCM_MANIFEST" >> ${SHARED_DIR}/ccm-manifests.txt
echo "CCM_STATUS_KEY=.status.availableReplicas" >> "${SHARED_DIR}/deploy.env"
cp -v ${SHARED_DIR}/ccm-manifests.txt ${ARTIFACT_DIR}/

cat << EOF > "${SHARED_DIR}/ccm.env"
CCM_RESOURCE="Deployment/aws-cloud-controller-manager"
CCM_NAMESPACE=${CCM_NAMESPACE}
CCM_REPLICAS_COUNT=2
EOF