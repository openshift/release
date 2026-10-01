#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  fi
fi

SSH_USER=$(cat "${SHARED_DIR}/ssh_user")
HOST_IP=$(cat "${SHARED_DIR}/public_address")
SSH_OPTS=(-o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "${CLUSTER_PROFILE_DIR}/ssh-privatekey")

function remote() {
  ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST_IP}" "$@"
}

echo "Waiting for SSH connectivity to ${HOST_IP}..."
SECONDS=0
until remote true 2>/dev/null; do
  if (( SECONDS > 300 )); then
    echo "ERROR: SSH timeout after ${SECONDS}s"
    remote true
    exit 1
  fi
  sleep 5
done
echo "SSH connected after ${SECONDS}s"

echo "Waiting for cloud-init to finish..."
remote "sudo cloud-init status --wait || true"

echo "Verifying tools..."
remote "kind version && kubectl version --client && docker version"

remote bash -s << 'REMOTE_SCRIPT'
set -euo pipefail

echo "=== Creating kind cluster ==="
CREATE_START=$(date +%s)
kind create cluster --name poc --wait 180s --verbosity 4
CREATE_END=$(date +%s)
echo "=== kind cluster created in $((CREATE_END - CREATE_START))s ==="

export KUBECONFIG=$(kind get kubeconfig --name poc 2>/dev/null > /tmp/kubeconfig && echo /tmp/kubeconfig)
kind get kubeconfig --name poc > /tmp/kubeconfig
export KUBECONFIG=/tmp/kubeconfig

echo "=== Cluster nodes ==="
kubectl get nodes -o wide

echo "=== Deploying nginx hello-world ==="
kubectl create deployment hello --image=nginx:alpine --replicas=1
kubectl expose deployment hello --port=80 --type=ClusterIP

echo "=== Waiting for pod ready ==="
kubectl wait --for=condition=Ready pod -l app=hello --timeout=120s

echo "=== Pod status ==="
kubectl get pods -o wide
kubectl get svc hello

echo "=== Curling the service ==="
SVC_IP=$(kubectl get svc hello -o jsonpath='{.spec.clusterIP}')
kubectl run curl-test --image=curlimages/curl --rm -i --restart=Never -- \
  curl -s --max-time 10 "http://${SVC_IP}" < /dev/null

echo "=== Cleanup first cluster ==="
DELETE_START=$(date +%s)
kind delete cluster --name poc
DELETE_END=$(date +%s)
echo "=== kind cluster deleted in $((DELETE_END - DELETE_START))s ==="

echo "=== Second run (images cached) ==="
CREATE2_START=$(date +%s)
kind create cluster --name poc2 --wait 180s --verbosity 4
CREATE2_END=$(date +%s)
echo "=== kind cluster created (cached) in $((CREATE2_END - CREATE2_START))s ==="

DELETE2_START=$(date +%s)
kind delete cluster --name poc2
DELETE2_END=$(date +%s)
echo "=== kind cluster deleted (cached) in $((DELETE2_END - DELETE2_START))s ==="

echo "=== Timing summary ==="
echo "  First create:  $((CREATE_END - CREATE_START))s"
echo "  First delete:  $((DELETE_END - DELETE_START))s"
echo "  Second create: $((CREATE2_END - CREATE2_START))s (images cached)"
echo "  Second delete: $((DELETE2_END - DELETE2_START))s"
echo "=== SUCCESS: kind on EC2 works ==="
REMOTE_SCRIPT
