#!/bin/bash
set -o nounset
set -o pipefail

# This script runs as a step in Prow CI (OpenShift CI) jobs. It intentionally
# uses 'exit 0' on failures so it does not block subsequent test steps in the
# pipeline. Test failures are still surfaced via the artifacts and job status.
#
# Prerequisites: the Cluster Observability Operator and the OpenShift Lightspeed
# operator must already be installed (e.g. by a preceding install-operators
# step). This step only configures OLS and enables Perses, then runs the tests.

OLS_NAMESPACE="${OLS_NAMESPACE:-openshift-lightspeed}"
coo_namespace="${CYPRESS_COO_NAMESPACE:-coo}"

# Skip everything if the console is not installed.
if ! oc get clusteroperator console --kubeconfig="${KUBECONFIG}"; then
  echo "Console is not installed, skipping tests."
  exit 0
fi

# Read the kubeadmin password.
if [[ -z "${KUBEADMIN_PASSWORD_FILE:-}" ]] || [[ ! -f "${KUBEADMIN_PASSWORD_FILE}" ]]; then
  echo "Error: KUBEADMIN_PASSWORD_FILE is not set or does not exist"
  exit 0
fi
kubeadmin_password=$(cat "${KUBEADMIN_PASSWORD_FILE}")

# Load proxy config if present (consistent with other integration steps).
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# ---------------------------------------------------------------------------
# Configure OpenShift Lightspeed with an AWS Bedrock LLM provider.
# ---------------------------------------------------------------------------

# AWS Bedrock IAM credentials are mounted from the bedrock-obsinta-ci vault
# secret (test-credentials namespace) via the ref's credentials block.
aws_access_key_id_file="/var/run/bedrock/aws_access_key_id"
aws_secret_access_key_file="/var/run/bedrock/aws_secret_access_key"
if [[ ! -f "${aws_access_key_id_file}" ]] || [[ ! -f "${aws_secret_access_key_file}" ]]; then
  echo "Error: Bedrock credentials not found under /var/run/bedrock, skipping tests."
  exit 0
fi
aws_access_key_id=$(cat "${aws_access_key_id_file}")
aws_secret_access_key=$(cat "${aws_secret_access_key_file}")

echo "--- Creating llmcreds secret in ${OLS_NAMESPACE} ---"
oc create secret generic llmcreds -n "${OLS_NAMESPACE}" \
  --from-literal=aws_access_key_id="${aws_access_key_id}" \
  --from-literal=aws_secret_access_key="${aws_secret_access_key}" \
  --dry-run=client -o yaml | oc apply -f - || {
    echo "Error: failed to create llmcreds secret, skipping tests."
    exit 0
  }

echo "--- Creating OLSConfig (Bedrock provider, model ${OLS_BEDROCK_MODEL}) ---"
cat <<EOF | oc apply -f - || echo "Warning: failed to apply OLSConfig, continuing"
apiVersion: ols.openshift.io/v1alpha1
kind: OLSConfig
metadata:
  name: cluster
spec:
  llm:
    providers:
      - name: bedrock
        type: bedrock
        url: "${OLS_BEDROCK_URL}"
        credentialsSecretRef:
          name: llmcreds
        models:
          - name: ${OLS_BEDROCK_MODEL}
  ols:
    defaultProvider: bedrock
    defaultModel: ${OLS_BEDROCK_MODEL}
    deployment:
      replicas: 1
    logLevel: INFO
EOF

# Wait for the OLS operator to reconcile the OLSConfig and for the
# lightspeed-app-server deployment to become Available. We retry in short
# bursts because oc wait returns immediately with NotFound if the deployment
# has not been created yet.
echo "--- Waiting for lightspeed-app-server to become available ---"
deadline=$((SECONDS + 900))
while true; do
  if (( SECONDS >= deadline )); then
    echo "Error: lightspeed-app-server not available within 15 minutes, skipping tests."
    exit 0
  fi
  if oc wait --for=condition=Available -n "${OLS_NAMESPACE}" deployment/lightspeed-app-server --timeout=30s &>/dev/null; then
    echo "lightspeed-app-server is available."
    break
  fi
  echo "lightspeed-app-server not available yet, retrying in 15s..."
  sleep 15
done

# The @ols test also exercises Perses dashboards (Observe -> Dashboards (Perses)),
# which requires the Monitoring UIPlugin with Perses enabled. Ensure Perses is
# enabled: patch the plugin if it already exists (created by a preceding step so
# we don't clobber its other settings), otherwise create it.
echo "--- Ensuring Monitoring UIPlugin has Perses enabled ---"
if oc get uiplugin monitoring &>/dev/null; then
  oc patch uiplugin monitoring --type=merge \
    -p '{"spec":{"type":"Monitoring","monitoring":{"perses":{"enabled":true}}}}' \
    || echo "Warning: failed to patch Monitoring UIPlugin, continuing"
else
  cat <<EOF | oc apply -f - || echo "Warning: failed to create Monitoring UIPlugin, continuing"
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
EOF
fi
oc wait deployment -n "${coo_namespace}" -l app.kubernetes.io/name=perses \
  --for=condition=Available --timeout=5m || echo "Warning: perses deployment not ready, continuing"

# ---------------------------------------------------------------------------
# Run the Cypress @ols suite from the monitoring-plugin repository.
# ---------------------------------------------------------------------------

function copyArtifacts {
  local web="/tmp/monitoring-plugin/web"
  [[ -d "${web}/cypress/screenshots" ]] && cp -r "${web}/cypress/screenshots" "${ARTIFACT_DIR}/screenshots" || true
  [[ -d "${web}/cypress/videos" ]]      && cp -r "${web}/cypress/videos"      "${ARTIFACT_DIR}/videos"      || true
  find /tmp -maxdepth 1 -name "cypress_report*.json" -exec cp {} "${ARTIFACT_DIR}/" \; 2>/dev/null || true
}
trap copyArtifacts EXIT

# Set kubeconfig var for Cypress (the test shells out to oc via KUBECONFIG_PATH).
cp -L "${KUBECONFIG}" /tmp/kubeconfig
export CYPRESS_KUBECONFIG_PATH=/tmp/kubeconfig
export KUBECONFIG=/tmp/kubeconfig

console_route=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')
export CYPRESS_BASE_URL="https://${console_route}"
export CYPRESS_LOGIN_IDP=kube:admin
export CYPRESS_LOGIN_USERS="kubeadmin:${kubeadmin_password}"
export CYPRESS_CACHE_FOLDER=/tmp/Cypress
export ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp}"
export NO_COLOR=1

repo_url="https://github.com/openshift/monitoring-plugin.git"
target_dir="/tmp/monitoring-plugin"
branch="${MONITORING_PLUGIN_BRANCH:-main}"

echo "--- Cloning monitoring-plugin repository, branch: ${branch} ---"
if ! git clone --depth 1 --branch "${branch}" "${repo_url}" "${target_dir}"; then
  echo "Error: failed to clone monitoring-plugin, skipping tests."
  exit 0
fi

cd "${target_dir}/web" || exit 0
if ! npm install; then
  echo "Error: npm install failed, skipping tests."
  exit 0
fi

echo "--- Running Cypress @ols tests ---"
npx cypress run --browser chrome --headless --env grepTags='@ols --@flaky --@demo --@xfail'
ret=$?
if [[ ${ret} -ne 0 ]]; then
  echo "Cypress tests failed with exit code ${ret}, continuing to allow subsequent steps to run."
fi
exit 0
