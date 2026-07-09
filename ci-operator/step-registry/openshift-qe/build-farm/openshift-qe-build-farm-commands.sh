#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
oc version
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

# Replace CRI-O binary on all nodes with a custom build to test fix for
# continuous CNI STATUS polling memory regression (cri-o/cri-o#9855)
CRIO_BINARY_URL="https://files.cornea.dev/api/public/dl/4D1egEfq?inline=true"
echo "Replacing CRI-O binary from ${CRIO_BINARY_URL} on all nodes"
cat > /tmp/replace-crio.sh <<'SCRIPT'
#!/bin/bash
set -euo pipefail
CRIO_PATH="/var/lib/crio-custom"
if [[ ! -f "${CRIO_PATH}" ]]; then
    url="https://files.cornea.dev/api/public/dl/4D1egEfq?inline=true"
    curl -sL --retry 5 --retry-delay 3 -o "${CRIO_PATH}" "${url}"
    chmod +x "${CRIO_PATH}"
    chcon -t container_runtime_exec_t "${CRIO_PATH}"
    ${CRIO_PATH} --version || { echo "Downloaded binary is not valid"; rm -f "${CRIO_PATH}"; exit 1; }
fi
mount --bind "${CRIO_PATH}" /usr/bin/crio
SCRIPT
ENCODED_SCRIPT=$(base64 -w 0 /tmp/replace-crio.sh)

oc apply -f- <<EOF
apiVersion: v1
kind: List
items:
- apiVersion: machineconfiguration.openshift.io/v1
  kind: MachineConfig
  metadata:
    labels:
      machineconfiguration.openshift.io/role: worker
    name: crio-replace-worker
  spec:
    config:
      ignition:
        version: 3.2.0
      storage:
        files:
        - path: /usr/local/bin/replace-crio.sh
          mode: 0755
          overwrite: true
          contents:
            source: "data:text/plain;base64,${ENCODED_SCRIPT}"
      systemd:
        units:
        - name: replace-crio.service
          enabled: true
          contents: |
            [Unit]
            Description=Replace CRI-O binary with custom build
            Before=crio.service
            After=network-online.target
            Wants=network-online.target
            [Service]
            Type=oneshot
            ExecStart=/usr/local/bin/replace-crio.sh
            RemainAfterExit=true
            [Install]
            WantedBy=multi-user.target
- apiVersion: machineconfiguration.openshift.io/v1
  kind: MachineConfig
  metadata:
    labels:
      machineconfiguration.openshift.io/role: master
    name: crio-replace-master
  spec:
    config:
      ignition:
        version: 3.2.0
      storage:
        files:
        - path: /usr/local/bin/replace-crio.sh
          mode: 0755
          overwrite: true
          contents:
            source: "data:text/plain;base64,${ENCODED_SCRIPT}"
      systemd:
        units:
        - name: replace-crio.service
          enabled: true
          contents: |
            [Unit]
            Description=Replace CRI-O binary with custom build
            Before=crio.service
            After=network-online.target
            Wants=network-online.target
            [Service]
            Type=oneshot
            ExecStart=/usr/local/bin/replace-crio.sh
            RemainAfterExit=true
            [Install]
            WantedBy=multi-user.target
- apiVersion: machineconfiguration.openshift.io/v1
  kind: MachineConfig
  metadata:
    labels:
      machineconfiguration.openshift.io/role: infra
    name: crio-replace-infra
  spec:
    config:
      ignition:
        version: 3.2.0
      storage:
        files:
        - path: /usr/local/bin/replace-crio.sh
          mode: 0755
          overwrite: true
          contents:
            source: "data:text/plain;base64,${ENCODED_SCRIPT}"
      systemd:
        units:
        - name: replace-crio.service
          enabled: true
          contents: |
            [Unit]
            Description=Replace CRI-O binary with custom build
            Before=crio.service
            After=network-online.target
            Wants=network-online.target
            [Service]
            Type=oneshot
            ExecStart=/usr/local/bin/replace-crio.sh
            RemainAfterExit=true
            [Install]
            WantedBy=multi-user.target
metadata:
  resourceVersion: ""
EOF
sleep 30
echo "Waiting for MachineConfigPools to finish updating..."
for i in $(seq 1 90); do
    if oc wait mcp --all --for=condition=Updated=True --timeout=30s 2>/dev/null; then
        echo "All MachineConfigPools updated successfully"
        break
    fi
    echo "MachineConfigPools still updating (attempt ${i}/90)..."
    oc get mcp
    sleep 30
done
echo "CRI-O binary replacement complete on all nodes"

export WORKLOAD=build-farm

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi
EXTRA_FLAGS+="${BUILD_FARM_EXTRA_FLAGS} --gc-metrics=false --profile-type=${PROFILE_TYPE}"

if [[ -n "${USER_METADATA}" ]]; then
  echo "${USER_METADATA}" > user-metadata.yaml
  EXTRA_FLAGS+=" --user-metadata=user-metadata.yaml"
fi
export EXTRA_FLAGS
export ADDITIONAL_PARAMS

./run.sh

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
fi
