#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  set +x
  source "${SHARED_DIR}/proxy-conf.sh"
  set -x
fi

# Read values from setup step
CLIENT_NODE=$(cat "${SHARED_DIR}/ext_client_node")
SERVER_NODE=$(cat "${SHARED_DIR}/ext_server_node")
START_IP=$(cat "${SHARED_DIR}/ext_start_ip")
END_IP=$(cat "${SHARED_DIR}/ext_end_ip")

echo "CLIENT_NODE=$CLIENT_NODE SERVER_NODE=$SERVER_NODE"
echo "START_IP=$START_IP END_IP=$END_IP"

# ES credentials from vault
ES_HOST=""
ES_PASSWORD=$(cat "${ES_SECRETS_PATH}/password")
ES_USERNAME=$(cat "${ES_SECRETS_PATH}/username")
if [ -e "${ES_SECRETS_PATH}/host" ]; then
  ES_HOST=$(cat "${ES_SECRETS_PATH}/host")
fi
ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_HOST}"

# Install Go
GO_VERSION="1.25.0"
curl -sLO "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
tar -C /usr/local -xzf "go${GO_VERSION}.linux-amd64.tar.gz"
export PATH=$PATH:/usr/local/go/bin
go version

# Clone and build midterm_scenario_b
WORKDIR=$(mktemp -d)
git clone -b midterm_scenario_b https://github.com/venkataanil/kube-burner-ocp.git "${WORKDIR}/kube-burner-ocp"
pushd "${WORKDIR}/kube-burner-ocp"

# Fix images for OCP 5.0 (docker hub rate limit + override binary issue)
sed -i 's|docker.io/nicolaka/netshoot:latest|quay.io/sninganu/netshoot:latest|g' \
  cmd/config/cudn-density/deployment-client.yml
sed -i 's|quay.io/cloud-bulldozer/nginx:latest|quay.io/sninganu/nginx:latest|g' \
  cmd/config/cudn-density/deployment-server.yml

# Set nodeSelector for client and server pods
sed -i "s|kubernetes.io/hostname: ip-10-0-0-139.us-west-2.compute.internal|kubernetes.io/hostname: ${CLIENT_NODE}|g" \
  cmd/config/cudn-density/deployment-client.yml
sed -i "s|kubernetes.io/hostname: ip-10-0-0-176.us-west-2.compute.internal|kubernetes.io/hostname: ${SERVER_NODE}|g" \
  cmd/config/cudn-density/deployment-server.yml

# Set external IP range
sed -i "s|\$startIp := \"10.0.1.10\"|\$startIp := \"${START_IP}\"|g" \
  cmd/config/cudn-density/deployment-client.yml
sed -i "s|\$endIp := \"10.0.1.34\"|\$endIp := \"${END_IP}\"|g" \
  cmd/config/cudn-density/deployment-client.yml
sed -i "s|\$initStartIp := \"10.0.1.10\"|\$initStartIp := \"${START_IP}\"|g" \
  cmd/config/cudn-density/deployment-client.yml
sed -i "s|\$initEndIp := \"10.0.1.34\"|\$initEndIp := \"${END_IP}\"|g" \
  cmd/config/cudn-density/deployment-client.yml

make clean; make build

# Run Scenario B
bin/amd64/kube-burner-ocp cudn-density \
  --bgp=false \
  --iterations="${ITERATIONS}" \
  --namespaces-per-cudn=1 \
  --es-server="${ES_SERVER}" \
  --es-index="${ES_INDEX}" \
  --gc="${GC}" \
  --log-level=debug \
  --timeout="${TIMEOUT}" \
  --burst="${BURST}" \
  --qps="${QPS}" \
  --ignore-health-check

popd
