#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function turn_down() {
  touch /tmp/ccm.done
}
trap turn_down EXIT

export KUBECONFIG=${SHARED_DIR}/kubeconfig

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

echo_date "Starting CCM setup"

echo_date "Collecting current cluster state"

echo_date "Infrastructure CR:"
oc get infrastructure -o yaml

echo_date "Nodes:"
oc get nodes

echo_date "Pods:"
oc get pods -A

if [[ "${PLATFORM_EXTERNAL_CCM_ENABLED-}" != "yes" ]]; then
  echo_date "Ignoring CCM Installation setup. PLATFORM_EXTERNAL_CCM_ENABLED!=yes [${PLATFORM_EXTERNAL_CCM_ENABLED}]"
  exit 0
fi

# Build from: https://github.com/openshift/cloud-provider-aws/blob/master/Dockerfile.openshift
CCM_IMAGE="quay.io/mrbraga/openshift-cloud-provider-aws:latest"
CCM_NAMESPACE=openshift-cloud-controller-manager

echo_date "Creating CloudController Manager deployment...."
cat << EOF | envsubst > "${SHARED_DIR}"/ccm-00-deployment.yaml
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

function stream_logs() {
  echo_date "[log-stream] Starting log streamer"
  oc logs deployment/aws-cloud-controller-manager -n ${CCM_NAMESPACE} >> ${ARTIFACT_DIR}/logs-ccm.txt 2>&1
  echo_date "[log-stream] Finish log streamer"
}

function watch_logs() {
  echo_date "[watcher] Starting watcher"
  while true; do
    test -f /tmp/ccm.done && break

    echo_date "[watcher] creating streamer..."
    stream_logs &
    PID_STREAM="$!"
    echo_date "[watcher] waiting streamer..."

    test -f /tmp/ccm.done && break
    sleep 10
    kill -9 "${PID_STREAM}" || true
  done
  echo_date "[watcher] done!"
}

echo_date "Creating watcher"
watch_logs &
PID_WATCHER="$!"

echo_date "Creating CCM deployment"
# oc create -f ${SHARED_DIR}/ccm-00-namespace.yaml
oc create -f "${SHARED_DIR}"/ccm-00-deployment.yaml

until  oc wait --for=jsonpath='{.status.availableReplicas}'=2 deployment.apps/aws-cloud-controller-manager -n ${CCM_NAMESPACE} --timeout=10m &> /dev/null
do
  echo_date "Waiting for minimum replicas avaialble..."
  sleep 10
done

echo_date "CCM Ready!"

oc get all -n ${CCM_NAMESPACE}

echo_date "Collecting logs for CCM initialization - initial 30 seconds"
sleep 30
touch /tmp/ccm.done

echo_date "Sent signal to finish watcher"
wait "$PID_WATCHER"

echo_date "Watcher done!"

oc get all -n ${CCM_NAMESPACE}