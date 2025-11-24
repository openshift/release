#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"

unset GOFLAGS
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
make e2e/local -o test/aro-hcp-tests
stop_tunnel
