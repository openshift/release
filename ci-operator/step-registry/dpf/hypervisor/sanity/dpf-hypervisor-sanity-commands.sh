#!/bin/bash
set -euo pipefail

echo "=== Verifying cluster access ==="
oc get co
oc get nodes -o wide
oc get dpu -A
oc get dpuservice -A
oc get application -A

cd /root/dpf-ci
cp "${SHARED_DIR}/.env" .env

echo "Updating .env file"
sed -i -E "s|^KUBECONFIG=.*$|KUBECONFIG=${KUBECONFIG}|" .env
sed -i -E 's|^VERIFY_DEPLOYMENT=.*$|VERIFY_DEPLOYMENT=true|' .env
sed -i -E 's|^VERIFY_MAX_RETRIES=.*$|VERIFY_MAX_RETRIES=4|' .env
sed -i -E 's|^VERIFY_SLEEP_SECONDS=.*$|VERIFY_SLEEP_SECONDS=3|' .env
grep -qx 'VERIFY_DEPLOYMENT=true' .env
grep -qx 'VERIFY_MAX_RETRIES=4' .env
grep -qx 'VERIFY_SLEEP_SECONDS=3' .env
cat .env | grep VERIFY
echo "VERIFY variables updated successfully"

echo "=== DPF Make Target checks on Existing Cluster ==="
make verify-workers
make verify-dpu-nodes
make verify-deployment
make verify-dpudeployment

echo "=== DPF Sanity Test ==="
datetime_string=$(date +"%Y-%m-%d_%H-%M-%S")

if make run-dpf-sanity 2>&1 | tee "log-dpf-sanity-checks-${datetime_string}"; then
  echo "Sanity Test Passed"
  exit 0
fi

echo "Sanity Test Failed"
exit 1
