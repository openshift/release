#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Validate and set KMS_VERSION
KMS_VERSION="${KMS_VERSION:-v2}"
if [[ "${KMS_VERSION}" != "v1" && "${KMS_VERSION}" != "v2" ]]; then
  echo "ERROR: KMS_VERSION must be 'v1' or 'v2', got: ${KMS_VERSION}"
  exit 1
fi

echo "========================================="
echo "Deploying mock KMS ${KMS_VERSION} plugin DaemonSet"
echo "========================================="

SOCKET_PATH="/var/run/kmsplugin/socket.sock"
KMS_NAMESPACE="openshift-kms-plugin"

# Create namespace for KMS plugin
echo "Creating namespace ${KMS_NAMESPACE}..."
oc create namespace "${KMS_NAMESPACE}" || echo "Namespace already exists"

# Create the DaemonSet that runs the KMS plugin
echo "Creating KMS plugin DaemonSet..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kms-plugin
  namespace: ${KMS_NAMESPACE}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kms-plugin-init
  namespace: ${KMS_NAMESPACE}
data:
  init.sh: |
    #!/bin/bash
    set -euxo pipefail

    echo "Installing build dependencies..."
    dnf install -y git golang

    echo "Cloning kubernetes repository..."
    cd /tmp
    git clone --depth=1 --filter=blob:none --sparse https://github.com/kubernetes/kubernetes.git
    cd kubernetes
    git sparse-checkout set staging/src/k8s.io/kms/internal/plugins/_mock

    echo "Building mock KMS plugin..."
    cd staging/src/k8s.io/kms/internal/plugins/_mock
    go build -o /plugin/mock-kms-provider .

    echo "Mock KMS plugin built successfully:"
    ls -lh /plugin/mock-kms-provider

    echo "Build complete. Plugin ready at /plugin/mock-kms-provider"
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kms-plugin
  namespace: ${KMS_NAMESPACE}
  labels:
    app: kms-plugin
spec:
  selector:
    matchLabels:
      app: kms-plugin
  template:
    metadata:
      labels:
        app: kms-plugin
    spec:
      serviceAccountName: kms-plugin
      hostNetwork: true
      hostPID: true
      nodeSelector:
        node-role.kubernetes.io/master: ""
      tolerations:
      - operator: Exists
      priorityClassName: system-node-critical
      initContainers:
      - name: build-plugin
        image: quay.io/openshift/origin-tools:latest
        command:
        - /bin/bash
        - /scripts/init.sh
        volumeMounts:
        - name: plugin-dir
          mountPath: /plugin
        - name: init-script
          mountPath: /scripts
        resources:
          requests:
            cpu: 500m
            memory: 1Gi
      containers:
      - name: kms-plugin
        image: quay.io/openshift/origin-tools:latest
        command:
        - /bin/bash
        - -c
        - |
          set -euxo pipefail
          echo "Starting mock KMS \${KMS_VERSION} plugin..."
          mkdir -p /var/run/kmsplugin
          if [[ "\${KMS_VERSION}" == "v1" ]]; then
            echo "Using KMS v1 API"
            exec /plugin/mock-kms-provider --listen-addr=unix://${SOCKET_PATH} -v=5
          else
            echo "Using KMS v2 API"
            exec /plugin/mock-kms-provider --listen-addr=unix://${SOCKET_PATH} --kms-api-version=v2 -v=5
          fi
        securityContext:
          privileged: true
        env:
        - name: KMS_VERSION
          value: "${KMS_VERSION}"
        - name: GRPC_GO_LOG_VERBOSITY_LEVEL
          value: "99"
        - name: GRPC_GO_LOG_SEVERITY_LEVEL
          value: "info"
        volumeMounts:
        - name: kmsplugin
          mountPath: /var/run/kmsplugin
        - name: plugin-dir
          mountPath: /plugin
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
      volumes:
      - name: kmsplugin
        hostPath:
          path: /var/run/kmsplugin
          type: DirectoryOrCreate
      - name: plugin-dir
        emptyDir: {}
      - name: init-script
        configMap:
          name: kms-plugin-init
          defaultMode: 0755
EOF

echo ""
echo "Waiting for KMS plugin DaemonSet to be ready..."
echo "This may take a few minutes as the plugin is built on first run..."

# Wait for DaemonSet to be scheduled
sleep 10

# Wait for all pods to be ready
oc wait --for=condition=ready pod -l app=kms-plugin -n "${KMS_NAMESPACE}" --timeout=10m

echo ""
echo "Verifying KMS plugin deployment..."
oc get pods -n "${KMS_NAMESPACE}" -l app=kms-plugin -o wide

# Check plugin status on each control plane node
echo ""
echo "Checking KMS plugin socket on control plane nodes..."
MASTER_NODES=$(oc get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[*].metadata.name}')

for node in ${MASTER_NODES}; do
  echo "  Checking node: ${node}"

  # Get pod running on this node
  POD=$(oc get pods -n "${KMS_NAMESPACE}" -l app=kms-plugin --field-selector spec.nodeName="${node}" -o jsonpath='{.items[0].metadata.name}')

  if [ -n "${POD}" ]; then
    echo "    Pod: ${POD}"

    # Check if socket exists
    if oc exec -n "${KMS_NAMESPACE}" "${POD}" -- test -S "${SOCKET_PATH}" 2>/dev/null; then
      echo "    ✓ Socket verified at ${SOCKET_PATH}"
    else
      echo "    ✗ Socket not found at ${SOCKET_PATH}"
      oc logs -n "${KMS_NAMESPACE}" "${POD}" --tail=50
      exit 1
    fi

    # Show recent logs
    echo "    Recent logs:"
    oc logs -n "${KMS_NAMESPACE}" "${POD}" --tail=5 | sed 's/^/      /'
  fi
done

# Save socket path, namespace, and version for other steps to use
echo "${SOCKET_PATH}" > "${SHARED_DIR}/kms-plugin-socket-path"
echo "${KMS_NAMESPACE}" > "${SHARED_DIR}/kms-plugin-namespace"
echo "${KMS_VERSION}" > "${SHARED_DIR}/kms-plugin-version"

echo ""
echo "========================================="
echo "✓ Mock KMS ${KMS_VERSION} plugin deployed successfully!"
echo "  Namespace: ${KMS_NAMESPACE}"
echo "  Socket: ${SOCKET_PATH}"
echo "  API Version: ${KMS_VERSION}"
echo "  Ready for encryption configuration"
echo "========================================="
