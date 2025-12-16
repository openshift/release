#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
az account set --subscription "${SUBSCRIPTION_ID}"

unset GOFLAGS
make -C dev-infrastructure/ svc.aks.kubeconfig.pipeline SVC_KUBECONFIG_FILE=../kubeconfig DEPLOY_ENV=prow
export KUBECONFIG=kubeconfig
PIDFILE="/tmp/svc-tunnel.pid"
MONITOR_PIDFILE="/tmp/svc-monitor.pid"
NAMESPACE="aro-hcp"
SERVICE="aro-hcp-frontend"
LOCAL_PORT=8443
REMOTE_PORT=8443

wait_for_service() {
    for i in {1..5}; do
        if oc get svc -n "$NAMESPACE" "$SERVICE" >/dev/null 2>&1; then
            echo "Service $SERVICE found"
            return 0
        else
            echo "Service $SERVICE not found (attempt $i/5)"
            [[ $i -lt 5 ]] && sleep 10
        fi
    done
    echo "Service not available after 5 attempts, exiting"
    exit 1
}

start_port_forward() {
    echo "Starting port-forward..."
    pkill -f "oc.*port-forward.*$LOCAL_PORT" || true
    sleep 1
    oc port-forward -n "$NAMESPACE" "svc/$SERVICE" \
        "$LOCAL_PORT:$REMOTE_PORT" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    sleep 3
    if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Port forward running (PID: $(cat "$PIDFILE"))"
        return 0
    else
        echo "Port forward failed to start"
        rm -f "$PIDFILE"
        return 1
    fi
}

monitor_port_forward() {
    echo "Starting port-forward monitor..."
    while true; do
        if curl -s --connect-timeout 2 --max-time 3 "http://localhost:$LOCAL_PORT/" >/dev/null 2>&1; then
            sleep 5
        else
            echo "Port $LOCAL_PORT not responding, restarting port-forward..."
            if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
                kill "$(cat "$PIDFILE")" 2>/dev/null || true
                rm -f "$PIDFILE"
            fi
            if ! start_port_forward; then
                echo "Failed to restart port-forward, retrying in 10s..."
                sleep 10
            fi
        fi
    done
}

start_tunnel() {
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Port forward already running (PID: $(cat "$PIDFILE"))"
        return 0
    fi
    wait_for_service
    for attempt in {1..3}; do
        if start_port_forward; then
            break
        elif [[ $attempt -lt 3 ]]; then
            echo "Retrying port-forward start (attempt $((attempt + 1))/3)..."
            sleep 5
        else
            echo "Failed to start port-forward after 3 attempts"
            exit 1
        fi
    done

    monitor_port_forward &
    echo $! > "$MONITOR_PIDFILE"
    echo "Monitor started (PID: $(cat "$MONITOR_PIDFILE"))"
}

stop_tunnel() {
    if [[ -f "$MONITOR_PIDFILE" ]] && kill -0 "$(cat "$MONITOR_PIDFILE")" 2>/dev/null; then
        echo "Stopping monitor (PID: $(cat "$MONITOR_PIDFILE"))"
        kill "$(cat "$MONITOR_PIDFILE")" 2>/dev/null || true
    fi
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "Stopping port forward (PID: $(cat "$PIDFILE"))"
        kill "$(cat "$PIDFILE")" 2>/dev/null || true
    fi
    # Clean up any remaining port-forwards
    pkill -f "oc.*port-forward.*$LOCAL_PORT" || true
    rm -f "$PIDFILE" "$MONITOR_PIDFILE" 2>/dev/null || true
    echo "Port forward stopped"
}

trap stop_tunnel EXIT

start_tunnel
make e2e/local -o test/aro-hcp-tests
stop_tunnel