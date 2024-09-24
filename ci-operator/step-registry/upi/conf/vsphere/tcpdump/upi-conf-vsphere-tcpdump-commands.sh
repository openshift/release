#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if [ "${COLLECTION_TCPDUMP_ENABLED}" == "false" ]; then
    echo "$(date -u --rfc-3339=seconds) - tcpdump collection disabled"
    exit 0
fi

echo "$(date -u --rfc-3339=seconds) - tcpdump collection enabled:"
echo "$(date -u --rfc-3339=seconds) - namespace: ${COLLECTION_NAMESPACE}"
echo "$(date -u --rfc-3339=seconds) - resource type: ${COLLECTION_RESOURCE_TYPE}"
echo "$(date -u --rfc-3339=seconds) - container name: ${COLLECTION_CONTAINER_NAME}"
echo "$(date -u --rfc-3339=seconds) - filter: ${COLLECTION_FILTER}"


cat > "${SHARED_DIR}"/tcpdump-collection-secret.yaml <<EOF
kind: Secret
apiVersion: v1
metadata:
  name: tcpdump-envvars
  namespace: default
data:
  COLLECTION_NAMESPACE: $(echo -n $COLLECTION_NAMESPACE | base64 -w0)
  COLLECTION_RESOURCE_TYPE: $(echo -n $COLLECTION_RESOURCE_TYPE | base64 -w0)
  COLLECTION_CONTAINER_NAME: $(echo -n $COLLECTION_CONTAINER_NAME | base64 -w0)
  COLLECTION_FILTER: $(echo -n $COLLECTION_FILTER | base64 -w0)
type: Opaque
EOF

cat > "${SHARED_DIR}"/tcpdump-collection.yaml <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: tcpdump-dns
  namespace: default
spec:
  selector:
    matchLabels:
      name: tcpdump-dns
  template:
    metadata:
      labels:
        name: tcpdump-dns
    spec:
      containers:
      - name: tcpdump-dns
        image: image-registry.openshift-image-registry.svc:5000/openshift/tools:latest
        envFrom:
        - secretRef:
            name: tcpdump-envvars
        command:
        - /bin/sh
        - -c
        - |
          #!/bin/sh

          export KUBECONFIG=/var/lib/kubelet/kubeconfig

          NAMESPACE="${COLLECTION_NAMESPACE}"
          RESOURCE_TYPE="${COLLECTION_RESOURCE_TYPE}"
          CONTAINER_NAME="${COLLECTION_CONTAINER_NAME}"
          FILTER="${COLLECTION_FILTER}"
          POD_JSON=$(chroot /host oc get "${RESOURCE_TYPE}" -n "${NAMESPACE}" -o json | jq -c --arg NODE_NAME "$(hostname)" --arg CONTAINER_NAME "${CONTAINER_NAME}" '.items[] | select(.spec.nodeName == $NODE_NAME) | select(.status.containerStatuses[].name == $CONTAINER_NAME)')
          CONTAINER_ID=$(echo $POD_JSON | jq -r --arg CONTAINER_NAME "${CONTAINER_NAME}" '.status.containerStatuses[] | select(.name == $CONTAINER_NAME) | .containerID')
          CONTAINER_ID=$(echo "${CONTAINER_ID}" | cut -d'/' -f3)
          echo $CONTAINER_ID

          ns_path=$(chroot /host crictl inspect "${CONTAINER_ID}" | jq '.info.runtimeSpec.linux.namespaces[] | select(.type=="network").path' -r)

          nsenter_parameters="--net=/host/${ns_path}"

          nsenter "${nsenter_parameters}" -- tcpdump "${FILTER}"
        volumeMounts:
        - name: host-root
          mountPath: /host
        - name: kubeconfig
          mountPath: /var/lib/kubelet/kubeconfig
          readOnly: true
        securityContext:
          privileged: true
          capabilities:
            add:
              - NET_ADMIN
              - SYS_TIME
        privileged: true
      hostNetwork: true
      hostPID: true
      serviceAccount: tcpdump
      serviceAccountName: tcpdump
      volumes:
      - name: host-root
        hostPath:
          path: /
      - name: kubeconfig
        hostPath:
          path: /var/lib/kubelet/kubeconfig
      tolerations:
      - key: "node-role.kubernetes.io/master"
        effect: "NoSchedule"
      - key: "node.kubernetes.io/not-ready"
        operator: "Exists"
      - key: "node-role.kubernetes.io/control-plane"
        effect: "NoSchedule"
EOF

echo "$(date -u --rfc-3339=seconds) - installing collection daemonset"
oc create sa -n default tcpdump
oc adm policy add-scc-to-user privileged -z tcpdump -n default
oc create -f "${SHARED_DIR}"/tcpdump-collection-secret.yaml
oc create -f "${SHARED_DIR}"/tcpdump-collection.yaml