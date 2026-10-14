#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  set +x
  source "${SHARED_DIR}/proxy-conf.sh"
  set -x
fi

oc config view
oc projects
pushd /tmp

# Configure Elasticsearch credentials
ES_SECRETS_PATH=${ES_SECRETS_PATH:-/secret}
WINDOWS_SECRETS_PATH=${WINDOWS_SECRETS_PATH:-/secret-perfci}

ES_HOST=${ES_HOST:-"search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"}
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
    ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi

# Retrieve Windows image URL from Vault
WINDOWS_IMAGE_URL=${WINDOWS_IMAGE_URL:-$(cat "${WINDOWS_SECRETS_PATH}/windows_url" 2>/dev/null || echo "")}
if [[ -z "${WINDOWS_IMAGE_URL}" ]]; then
    echo "ERROR: WINDOWS_IMAGE_URL is not set and windows_url not found in ${WINDOWS_SECRETS_PATH}"
    exit 1
fi

# Clone e2e-benchmarking repository
REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)"
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/kube-burner-ocp-wrapper

# Wait for cluster stabilization
echo "Waiting for nodes and MachineConfigPool to stabilize after day2 steps..."
max_wait=900
interval=20
elapsed=0
stabilized=false
while [ $elapsed -lt $max_wait ]; do
    if ! nodes=$(oc get nodes --no-headers 2>/dev/null); then
        sleep $interval
        elapsed=$((elapsed + interval))
        continue
    fi
    not_ready=$(grep -cv " Ready" <<< "$nodes" || true)
    mcp_updating=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}' 2>/dev/null || echo "")
    mcp_degraded=$(oc get mcp worker -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}' 2>/dev/null || echo "")
    if [ "$not_ready" -eq 0 ] && [ "$mcp_updating" = "False" ] && [ "$mcp_degraded" = "False" ]; then
        echo "All nodes Ready, worker MCP stable"
        stabilized=true
        break
    fi
    echo "Stabilizing... (not_ready=$not_ready, MCP updating=$mcp_updating, degraded=$mcp_degraded) [${elapsed}s/${max_wait}s]"
    sleep $interval
    elapsed=$((elapsed + interval))
done
if [ "$stabilized" = "false" ]; then
    echo "ERROR: Cluster did not stabilize within ${max_wait}s"
    exit 1
fi

# Set workload name
export WORKLOAD=windows-mssql
export KUBE_BURNER_VERSION

# Build EXTRA_FLAGS for windows-mssql workload
EXTRA_FLAGS="${MSSQL_EXTRA_FLAGS} --metrics-profile metrics.yml,cnv-metrics.yml --gc-metrics=false"
EXTRA_FLAGS+=" --windows-image-url=${WINDOWS_IMAGE_URL}"
EXTRA_FLAGS+=" --vms-per-node=${VMS_PER_NODE}"
EXTRA_FLAGS+=" --storage-class=${STORAGE_CLASS}"
EXTRA_FLAGS+=" --access-mode=${ACCESS_MODE}"
EXTRA_FLAGS+=" --eviction-strategy=${EVICTION_STRATEGY}"
EXTRA_FLAGS+=" --profile-type=${PROFILE_TYPE}"

# Storage backend flags
if [[ "${PER_NODE_DV}" == "true" ]]; then
    EXTRA_FLAGS+=" --per-node-dv"
fi
if [[ "${USE_SNAPSHOT}" == "true" ]]; then
    EXTRA_FLAGS+=" --use-snapshot"
fi

# TPC-C benchmark configuration
EXTRA_FLAGS+=" --vm-cpus=${VM_CPUS}"
EXTRA_FLAGS+=" --vm-memory=${VM_MEMORY}"
EXTRA_FLAGS+=" --database-size=${DATABASE_SIZE}"
EXTRA_FLAGS+=" --worker-counts=${WORKER_COUNTS}"
EXTRA_FLAGS+=" --iterations=${ITERATIONS}"

# Elasticsearch configuration
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@$ES_HOST"

if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    EXTRA_FLAGS+=" --local-indexing"
fi

export EXTRA_FLAGS

# Install virtctl
[[ -n "${https_proxy:-}" ]] && https_proxy="${https_proxy/socks5:/socks5h:}"
[[ -n "${http_proxy:-}" ]] && http_proxy="${http_proxy/socks5:/socks5h:}"
VIRTCTL_URL=$(oc get consoleclidownload virtctl-clidownloads-kubevirt-hyperconverged \
    -o jsonpath='{.spec.links[?(@.text=="Download virtctl for Linux for x86_64")].href}')
curl -skL -o /tmp/virtctl.tar.gz "${VIRTCTL_URL}"
gzip -t /tmp/virtctl.tar.gz 2>/dev/null || { echo "ERROR: virtctl download failed"; exit 1; }
mkdir -p /tmp/bin
tar -xzf /tmp/virtctl.tar.gz -C /tmp/bin/
chmod +x /tmp/bin/virtctl
export PATH="/tmp/bin:${PATH}"
rm -f /tmp/virtctl.tar.gz
virtctl version --client

# Run the workload
./run.sh

# Collect artifacts
if [[ "${ENABLE_LOCAL_INDEX}" == "true" ]]; then
    metrics_folder_name=$(find . -maxdepth 1 -type d -name 'collected-metric*' | head -n 1)
    if [[ -n "${metrics_folder_name}" ]]; then
        cp -r "${metrics_folder_name}" "${ARTIFACT_DIR}/"
    fi
fi
