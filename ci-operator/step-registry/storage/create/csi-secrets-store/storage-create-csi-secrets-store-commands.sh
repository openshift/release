#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

export CLUSTER_CSI_DRIVER_NAME="secrets-store.csi.k8s.io"
export E2E_PROVIDER_DAEMONSET_LOCATION=${SHARED_DIR}/e2e-provider.yaml
export E2E_PROVIDER_NAMESPACE=openshift-cluster-csi-drivers
export E2E_PROVIDER_SERVICE_ACCOUNT=csi-secrets-store-e2e-provider-sa
export E2E_PROVIDER_APP_LABEL=csi-secrets-store-e2e-provider
export E2E_PROVIDER_SELECTOR="app=${E2E_PROVIDER_APP_LABEL}"

echo "Creating ClusterCSIDriver ${CLUSTER_CSI_DRIVER_NAME}"
oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
    name: ${CLUSTER_CSI_DRIVER_NAME}
spec:
  managementState: Managed
EOF
echo "Created ClusterCSIDriver ${CLUSTER_CSI_DRIVER_NAME}"

# e2e-provider must be privileged to bind to a unix domain socket on the host.
echo "Creating E2E Provider ServiceAccount"
oc create serviceaccount -n ${E2E_PROVIDER_NAMESPACE} ${E2E_PROVIDER_SERVICE_ACCOUNT}
oc adm policy add-scc-to-user privileged system:serviceaccount:${E2E_PROVIDER_NAMESPACE}:${E2E_PROVIDER_SERVICE_ACCOUNT}
echo "Created E2E Provider ServiceAccount"

echo "Creating E2E Provider DaemonSet"
cat <<EOF >${E2E_PROVIDER_DAEMONSET_LOCATION}
apiVersion: apps/v1
kind: DaemonSet
metadata:
  labels:
    app: ${E2E_PROVIDER_APP_LABEL}
  name: csi-secrets-store-e2e-provider
  namespace: ${E2E_PROVIDER_NAMESPACE}
spec:
  updateStrategy:
    type: RollingUpdate
  selector:
    matchLabels:
      app: ${E2E_PROVIDER_APP_LABEL}
  template:
    metadata:
      labels:
        app: ${E2E_PROVIDER_APP_LABEL}
    spec:
      serviceAccountName: ${E2E_PROVIDER_SERVICE_ACCOUNT}
      containers:
        - name: e2e-provider
          image: ${SECRETS_STORE_E2E_PROVIDER_IMAGE}
          imagePullPolicy: IfNotPresent
          args:
            - --endpoint=unix:///provider/e2e-provider.sock
          resources:
            requests:
              cpu: 50m
              memory: 100Mi
            limits:
              cpu: 50m
              memory: 100Mi
          securityContext:
            privileged: true
          volumeMounts:
            - mountPath: "/provider"
              name: providervol
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: type
                operator: NotIn
                values:
                - virtual-kubelet
      volumes:
        - name: providervol
          hostPath:
            path: "/var/run/secrets-store-csi-providers"
      nodeSelector:
        kubernetes.io/os: linux
EOF

echo "Using E2E Provider DaemonSet file ${E2E_PROVIDER_DAEMONSET_LOCATION}"
cat ${E2E_PROVIDER_DAEMONSET_LOCATION}

oc create -f ${E2E_PROVIDER_DAEMONSET_LOCATION}
echo "Created E2E Provider DaemonSet from file ${E2E_PROVIDER_DAEMONSET_LOCATION}"

echo "Getting list of worker nodes on the cluster"
oc get nodes --selector='node-role.kubernetes.io/worker' --no-headers
NUM_WORKER_NODES=$(oc get nodes --selector='node-role.kubernetes.io/worker' --no-headers | wc -l)
echo "NUM_WORKER_NODES = ${NUM_WORKER_NODES}"

echo "Waiting for E2E Provider pods to be Ready"
E2E_PROVIDER_GET_ARGS="-n ${E2E_PROVIDER_NAMESPACE} --selector=${E2E_PROVIDER_SELECTOR}"
OC_WAIT_ARGS="--for=jsonpath=.status.numberReady=${NUM_WORKER_NODES} --timeout=300s"
if ! oc wait daemonset ${E2E_PROVIDER_GET_ARGS} ${OC_WAIT_ARGS}; then
	oc describe daemonset ${E2E_PROVIDER_GET_ARGS}
	oc get daemonset ${E2E_PROVIDER_GET_ARGS} -o yaml
	echo "Wait failed, E2E Provider pods did not reach Ready state"
	exit 1
fi
oc get pods ${E2E_PROVIDER_GET_ARGS}
echo "E2E Provider pods are Ready"
