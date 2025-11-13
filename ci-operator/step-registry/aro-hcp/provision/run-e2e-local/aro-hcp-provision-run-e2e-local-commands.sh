#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

set -x

# read the secrets and login as the user
export TEST_USER_CLIENT_ID; TEST_USER_CLIENT_ID=$(cat /var/run/hcp-integration-credentials/client-id)
export TEST_USER_CLIENT_SECRET; TEST_USER_CLIENT_SECRET=$(cat /var/run/hcp-integration-credentials/client-secret)
export TEST_USER_TENANT_ID; TEST_USER_TENANT_ID=$(cat /var/run/hcp-integration-credentials/tenant)
az login --service-principal -u "${TEST_USER_CLIENT_ID}" -p "${TEST_USER_CLIENT_SECRET}" --tenant "${TEST_USER_TENANT_ID}"
az bicep install
az bicep version
az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
az account show

# install required tools
mkdir -p /tmp/tools
az aks install-cli --install-location /tmp/tools/kubectl --kubelogin-install-location /tmp/tools/kubelogin
# Install newer curl with --json support
/tmp/tools/kubectl version
/tmp/tools/kubelogin --version

# Add to PATH
export PATH="/tmp/tools:$PATH"
PRINCIPAL_ID=$(az ad sp show --id "${TEST_USER_CLIENT_ID}" --query id -o tsv)
export PRINCIPAL_ID
unset GOFLAGS
make install-tools
PATH=$(go env GOPATH)/bin:$PATH
export PATH
make entrypoint/Region TIMING_OUTPUT=${SHARED_DIR}/steps.yaml DEPLOY_ENV=prow 

make -C dev-infrastructure/ svc.aks.kubeconfig SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV=prow
export KUBECONFIG=kubeconfig

PIDFILE="/tmp/svc-tunnel.pid"
start_tunnel() {
      if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
          echo "Port forward already running (PID: $(cat "$PIDFILE"))"
          return 0
      fi
      for i in {1..3}; do
          if kubectl get svc -n aro-hcp aro-hcp-frontend >/dev/null 2>&1; then
              echo "Service aro-hcp-frontend found"
              break
          else
              echo "Service aro-hcp-frontend not found"
              if [[ $i -lt 3 ]]; then
                  echo "Waiting 10 seconds before retry..."
                  sleep 10
              else
                  echo "Service not available after 3 attempts, exiting"
                  exit 1
              fi
          fi
      done
      kubectl port-forward -n aro-hcp svc/aro-hcp-frontend 8443:8443 >/dev/null 2>&1 &
      echo $! > "$PIDFILE"

      echo "Port forward started (PID: $(cat "$PIDFILE"))"
      sleep 2
      if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
          echo "Service is running successfully"
      else
          echo "Failed to start port forward"
          rm -f "$PIDFILE"
          exit 1
      fi
}

stop_tunnel() {
      if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
          kill "$(cat "$PIDFILE")"
          rm -f "$PIDFILE"
          echo "Port forward stopped"
      else
          echo "No port forward running"
          rm -f "$PIDFILE" 2>/dev/null || true
      fi
}
start_tunnel
unset GOFLAGS
export LOCATION="westus3"
export AROHCP_ENV="development"
curl -L https://github.com/moparisthebest/static-curl/releases/latest/download/curl-amd64 -o /tmp/tools/curl
chmod +x /tmp/tools/curl
curl --version
cd demo
./01-register-sub.sh
cd ..
make -C test/
./test/aro-hcp-tests run-suite "rp-api-compat-all/parallel" --junit-path="${ARTIFACT_DIR}/junit.xml"
stop_tunnel
