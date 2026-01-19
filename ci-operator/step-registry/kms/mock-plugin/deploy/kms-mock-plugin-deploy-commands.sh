#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Building mock KMS plugin and creating MachineConfig manifest..."

# Install golang if not available
if ! command -v go &> /dev/null; then
    echo "Installing golang..."
    dnf install -y golang
fi

SOCKET_PATH="/var/run/kmsplugin/kms.sock"

# Build the mock KMS plugin binary
echo "Cloning and building mock KMS plugin..."
WORK_DIR=$(mktemp -d)
cd "${WORK_DIR}"

git clone --depth 1 --filter=blob:none --sparse https://github.com/openshift/kubernetes.git
cd kubernetes
git sparse-checkout set staging/src/k8s.io/kms/internal/plugins/_mock

echo "Building with CGO_ENABLED=1 (required for PKCS#11 support)..."
cd staging/src/k8s.io/kms/internal/plugins/_mock
CGO_ENABLED=1 go build -o mock-kms-provider .

echo "Mock KMS plugin built successfully"
ls -lh mock-kms-provider

# Base64 encode the binary for embedding in MachineConfig
echo "Base64 encoding binary..."
b64_binary=$(base64 -w 0 < mock-kms-provider)

# Create the MachineConfig manifest
cat > "${SHARED_DIR}/manifest_kms_plugin_machineconfig_master.yaml" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: master
  name: kms-mock-plugin-master
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - contents:
          source: data:application/octet-stream;base64,${b64_binary}
        filesystem: root
        mode: 0755
        path: /usr/local/bin/mock-kms-provider
    systemd:
      units:
      - contents: |
          [Unit]
          Description=Setup SoftHSM for KMS plugin
          After=network-online.target
          Wants=network-online.target
          Before=kubelet.service
          ConditionPathExists=!/var/lib/softhsm/.initialized

          [Service]
          Type=oneshot
          ExecStart=/bin/bash -c 'rpm-ostree usroverlay && \
            dnf install -y softhsm opensc && \
            mkdir -p /var/lib/softhsm/tokens && \
            softhsm2-util --init-token --free --label kms-token --pin 1234 --so-pin 1234 && \
            pkcs11-tool --module /usr/lib64/softhsm/libsofthsm2.so --keygen --key-type aes:32 --pin 1234 --token-label kms-token --label kms-test && \
            touch /var/lib/softhsm/.initialized'
          RemainAfterExit=yes

          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: setup-softhsm.service
      - contents: |
          [Unit]
          Description=Mock KMS v2 Plugin
          After=network.target setup-softhsm.service
          Before=kubelet.service

          [Service]
          Type=simple
          Restart=always
          RestartSec=10
          Environment="GRPC_GO_LOG_VERBOSITY_LEVEL=99"
          Environment="GRPC_GO_LOG_SEVERITY_LEVEL=info"
          ExecStartPre=/usr/bin/mkdir -p /var/run/kmsplugin
          ExecStart=/usr/local/bin/mock-kms-provider --listen-addr=unix://${SOCKET_PATH} -v=5
          StandardOutput=journal
          StandardError=journal

          [Install]
          WantedBy=multi-user.target
        enabled: true
        name: mock-kms-plugin.service
EOF

echo "MachineConfig manifest created successfully"
echo "---------------------------------------------"
cat "${SHARED_DIR}/manifest_kms_plugin_machineconfig_master.yaml"
echo "---------------------------------------------"

# Save socket path for other steps
echo "${SOCKET_PATH}" > "${SHARED_DIR}/kms-plugin-socket-path"

echo ""
echo "Mock KMS v2 plugin MachineConfig created successfully!"
echo "The systemd service will start automatically on control plane nodes at boot."
echo "Plugin will be available at: unix://${SOCKET_PATH}"
echo "To use in EncryptionConfiguration, reference: unix://${SOCKET_PATH}"

# Cleanup
cd /
rm -rf "${WORK_DIR}"