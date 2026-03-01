#!/bin/bash
set -o nounset
set -o pipefail

# This script is a customized version for running COO ACM Alerting UI tests.
# The script use for clusters that has acm installed.
# The script will enable UIPlugin and add test alerts first, then start cypress test.
# We use '|| true' on the final cypress command to ensure that the script does not exit with 1.

echo "--- Applying UIPlugin CR to integrate ACM observability into the console ---"
cat <<EOF | oc apply -f -
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  monitoring:
    acm:
      enabled: true
      alertmanager:
        url: 'https://alertmanager.open-cluster-management-observability.svc:9095'
      thanosQuerier:
        url: 'https://rbac-query-proxy.open-cluster-management-observability.svc:8443'
  type: Monitoring
EOF

echo "--- Applying UIPlugin test alerts ---"
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: thanos-ruler-custom-rules
  namespace: open-cluster-management-observability
data:
  custom_rules.yaml: |
    groups:
      - name: alertrule-testing
        rules:
        - alert: Watchdog
          annotations:
            summary: An alert that should always be firing to certify that Alertmanager is working properly.
            description: This is an alert meant to ensure that the entire alerting pipeline is functional.
          expr: vector(1)
          labels:
            instance: "local"
            cluster: "local"
            clusterID: "111111111"
            severity: info
        - alert: Watchdog-spoke
          annotations:
            summary: An alert that should always be firing to certify that Alertmanager is working properly.
            description: This is an alert meant to ensure that the entire alerting pipeline is functional.
          expr: vector(1)
          labels:
            instance: "spoke"
            cluster: "spoke"
            clusterID: "22222222"
            severity: warn
      - name: cluster-health
        rules:
        - alert: ClusterCPUHealth-jb
          annotations:
            summary: Notify when CPU utilization on a cluster is greater than the defined utilization limit
            description: "The cluster has a high CPU usage: core for"
          expr: |
            max(cluster:cpu_usage_cores:sum) by (clusterID, cluster, prometheus) > 0
          labels:
            cluster: "{{ $labels.cluster }}"
            prometheus: "{{ $labels.prometheus }}"
            severity: critical
EOF

# Exit if console operator absent.
if ! (oc get clusteroperator console --kubeconfig=${KUBECONFIG}) ; then
  echo "Console is not installed, skipping all tests."
  exit 0
fi

# get KUBECONFIG.
if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "Error: KUBECONFIG variable is not set"
  exit 0
fi

if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "Error: Kubeconfig file ${KUBECONFIG} does not exist"
  exit 0
fi

# get kubeadmin password.
if [[ -z "${KUBEADMIN_PASSWORD_FILE:-}" ]]; then
  echo "Error: KUBEADMIN_PASSWORD_FILE variable is not set"
  exit 0
fi

if [[ ! -f "${KUBEADMIN_PASSWORD_FILE}" ]]; then
  echo "Error: Kubeadmin password file ${KUBEADMIN_PASSWORD_FILE} does not exist"
  exit 0
fi

kubeadmin_password=$(cat "${KUBEADMIN_PASSWORD_FILE}")
echo "Successfully read kubeadmin password from ${KUBEADMIN_PASSWORD_FILE}"

# Set Kubeconfig var for Cypress.
cp -L $KUBECONFIG /tmp/kubeconfig && export CYPRESS_KUBECONFIG_PATH=/tmp/kubeconfig

# Set Cypress test var.
console_route=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')
export CYPRESS_BASE_URL=https://$console_route
export CYPRESS_LOGIN_IDP=kube:admin
export CYPRESS_LOGIN_USERS=kubeadmin:${kubeadmin_password}

# Define the repository URL and target directory
repo_url="https://github.com/openshift/monitoring-plugin.git"
target_dir="/tmp/monitoring-plugin"

# Determine the branch to clone
branch="${MONITORING_PLUGIN_BRANCH:-main}"

echo "Cloning monitoring-plugin repository, branch: $branch"
git clone --depth 1 --branch "$branch" "$repo_url" "$target_dir"
if [ $? -eq 0 ]; then
  cd "$target_dir" || exit 0
  echo "Successfully cloned the repository and changed directory to $target_dir."
else
  echo "Error cloning the repository."
  exit 0
fi

# Install npm modules
cd web || exit 0
npm install || true

# run test
echo "--- Running COO ACM Alerting UI Cypress test ---"
npm run test-cypress-e2e -- --spec "cypress/e2e/coo/02.acm_alerting_ui.cy.ts"
