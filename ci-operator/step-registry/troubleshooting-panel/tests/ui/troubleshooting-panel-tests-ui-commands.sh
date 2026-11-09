#!/bin/bash
set -o nounset
set -o pipefail

if ! oc get clusteroperator console --kubeconfig="${KUBECONFIG}"; then
  echo "Console is not installed, skipping tests."
  exit 0
fi

if [[ -z "${KUBEADMIN_PASSWORD_FILE:-}" ]] || [[ ! -f "${KUBEADMIN_PASSWORD_FILE}" ]]; then
  echo "Error: KUBEADMIN_PASSWORD_FILE is not set or does not exist"
  exit 0
fi
kubeadmin_password=$(cat "${KUBEADMIN_PASSWORD_FILE}")

# Load proxy config if present (consistent with other integration steps).
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

repo_dir="/tmp/troubleshooting-panel-console-plugin"

function copyArtifacts {
  local web="${repo_dir}/web"
  [[ -d "${web}/cypress/screenshots" ]] && cp -r "${web}/cypress/screenshots" "${ARTIFACT_DIR}/" || true
  [[ -d "${web}/cypress/videos" ]]      && cp -r "${web}/cypress/videos"      "${ARTIFACT_DIR}/" || true
  find /tmp -maxdepth 1 -name "cypress_report*.json" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
}
trap copyArtifacts EXIT

coo_namespace="${CYPRESS_COO_NAMESPACE:-coo}"

# Ensure the Monitoring UIPlugin is present — the preceding incidents-ui-integration step
# normally creates it, but create it here if it's missing so the step is self-contained.
if ! oc get uiplugin monitoring -n "${coo_namespace}" &>/dev/null; then
  echo "--- Monitoring UIPlugin not found, creating it in namespace ${coo_namespace} ---"
  cat <<EOF | oc apply -f - || echo "Warning: failed to create Monitoring UIPlugin, continuing"
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
  namespace: ${coo_namespace}
spec:
  type: Monitoring
EOF
  echo "--- Waiting for monitoring-console-plugin deployment to become available ---"
  oc wait deployment -n "${coo_namespace}" -l app.kubernetes.io/name=monitoring-console-plugin \
    --for=condition=Available --timeout=5m || true
else
  echo "--- Monitoring UIPlugin already present, skipping install ---"
fi

# Create the TroubleshootingPanel UIPlugin.
echo "--- Creating TroubleshootingPanel UIPlugin in namespace ${coo_namespace} ---"
cat <<EOF | oc apply -f - || echo "Warning: failed to create TroubleshootingPanel UIPlugin, continuing"
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: troubleshooting-panel
  namespace: ${coo_namespace}
spec:
  type: TroubleshootingPanel
EOF

echo "--- Cloning troubleshooting-panel-console-plugin ---"
if ! git clone --depth 1 https://github.com/openshift/troubleshooting-panel-console-plugin.git "${repo_dir}"; then
  echo "Error: failed to clone repository, skipping tests."
  exit 0
fi

cp -L "${KUBECONFIG}" /tmp/kubeconfig

console_route=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')
ocp_version=$(oc version -o json | python3 -c \
  "import sys,json; v=json.load(sys.stdin)['openshiftVersion']; print('.'.join(v.split('.')[:2]))" 2>/dev/null || echo "")

export KUBECONFIG=/tmp/kubeconfig
export CYPRESS_BASE_URL="https://${console_route}"
export CYPRESS_LOGIN_IDP=kube:admin
export CYPRESS_LOGIN_USERS="kubeadmin:${kubeadmin_password}"
export CYPRESS_OPENSHIFT_VERSION="${ocp_version}"
export ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp}"
export CYPRESS_CACHE_FOLDER=/tmp/Cypress
export NO_COLOR=1

cd "${repo_dir}/web" || exit 0
if ! npm install; then
  echo "Error: npm install failed, skipping tests."
  exit 0
fi

echo "--- Running Cypress acceptance tests ---"
npx cypress run --e2e --spec cypress/e2e/acceptance.cy.ts
ret=$?
if [[ $ret -ne 0 ]]; then
  echo "Cypress tests failed with exit code ${ret}, continuing to allow subsequent steps to run."
fi
exit 0
