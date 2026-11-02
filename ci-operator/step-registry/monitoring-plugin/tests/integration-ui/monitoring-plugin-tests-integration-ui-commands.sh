#!/bin/bash
set -euo pipefail

vars=(
    CYPRESS_SKIP_COO_INSTALL
    CYPRESS_COO_NAMESPACE
    CYPRESS_MCP_CONSOLE_IMAGE
    CYPRESS_MP_IMAGE
    CYPRESS_TIMEZONE
    CYPRESS_SESSION
    CYPRESS_DEBUG
)

for var in "${vars[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        unset "$var"
        echo "Unset variable: $var"
    else
        echo "$var is set to '${!var}'"
    fi
done

# Read kubeadmin password from file
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

# Set proxy vars.
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

## skip all tests when console is not installed.
if ! oc get clusteroperator console --kubeconfig="${KUBECONFIG}"; then
    echo "console is not installed, skipping all console tests."
    exit 0
fi

monitoring_dir=/tmp/monitoring-plugin/web
tracing_dir=/tmp/distributed-tracing-console-plugin/tests
panel_dir=/tmp/troubleshooting-panel-console-plugin/web
suite=setup
test_dir="${monitoring_dir}"
result=0

function copyArtifacts {
    local artifact
    for artifact in cypress/screenshots cypress/videos cypress/logs gui_test_screenshots screenshots; do
        if [[ -d "${test_dir}/${artifact}" ]]; then
            mkdir -p "${ARTIFACT_DIR}/${suite}/${artifact}"
            cp -r "${test_dir}/${artifact}/." "${ARTIFACT_DIR}/${suite}/${artifact}/"
        fi
    done
}

# Copy the artifacts to the aritfact directory at the end of the test run.
trap copyArtifacts EXIT

# Set Kubeconfig var for Cypress.
cp -L "${KUBECONFIG}" /tmp/kubeconfig
export CYPRESS_KUBECONFIG_PATH=/tmp/kubeconfig

# Set Cypress base URL var.
console_route=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')
ocp_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d '.' -f1,2)

export CYPRESS_BASE_URL=https://$console_route

# Set Cypress authentication username and password.
# Use the IDP once issue https://issues.redhat.com/browse/OCPBUGS-59366 is fixed.
export CYPRESS_LOGIN_IDP=kube:admin
export CYPRESS_LOGIN_USERS=kubeadmin:${kubeadmin_password}

export CYPRESS_CACHE_FOLDER=/tmp/Cypress
export CYPRESS_OPENSHIFT_VERSION="${ocp_version}"
export NO_COLOR=1

for setting in TOKEN URL; do
    credential="/var/run/vault/dt-secrets/lightspeed-provider-${setting,,}"
    if [[ -f "${credential}" ]]; then
        export "CYPRESS_LIGHTSPEED_PROVIDER_${setting}=$(cat "${credential}")"
    fi
done

function runSuite {
    suite="$1"
    test_dir="$2"
    shift 2
    (cd "${test_dir}" && npm install && "$@") || result=1
    copyArtifacts
}

function waitForImage {
    local namespace="$1" selector="$2" image="$3"
    local deadline=$((SECONDS + 300))
    until oc get deployment -n "${namespace}" -l "${selector}" \
        -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' | grep -Fx "${image}"; do
        if ((SECONDS >= deadline)); then
            echo "Deployment ${selector} did not switch to the requested PR image."
            exit 1
        fi
        sleep 5
    done
    oc rollout status deployment -n "${namespace}" -l "${selector}" --timeout=300s
}

function waitForAvailable {
    local timeout="$1"
    shift
    local deadline=$((SECONDS + timeout))
    until oc wait "$@" --for=condition=Available --timeout=30s; do
        if ((SECONDS >= deadline)); then
            echo "Timed out waiting for $* to become available."
            exit 1
        fi
        sleep 15
    done
}

waitForAvailable 300 -n "${CYPRESS_COO_NAMESPACE}" deployment/observability-operator
cd "${monitoring_dir}"
MCP_NAMESPACE="${CYPRESS_COO_NAMESPACE}" MCP_CONSOLE_IMAGE="${CYPRESS_MCP_CONSOLE_IMAGE}" \
    bash -e cypress/fixtures/coo/update-mcp-image.sh
MP_NAMESPACE=openshift-monitoring MP_IMAGE="${CYPRESS_MP_IMAGE}" \
    bash -e cypress/fixtures/cmo/update-monitoring-plugin-image.sh
oc rollout status deployment/cluster-monitoring-operator -n openshift-monitoring --timeout=300s
oc apply -f - <<EOF
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
    clusterHealthAnalyzer:
      enabled: true
EOF
waitForImage openshift-monitoring app.kubernetes.io/name=monitoring-plugin "${CYPRESS_MP_IMAGE}"
waitForImage "${CYPRESS_COO_NAMESPACE}" app.kubernetes.io/instance=monitoring "${CYPRESS_MCP_CONSOLE_IMAGE}"
oc wait --for=create -n "${CYPRESS_COO_NAMESPACE}" statefulset/perses --timeout=300s
oc rollout status statefulset/perses -n "${CYPRESS_COO_NAMESPACE}" --timeout=300s

git clone --depth 1 --branch main https://github.com/openshift/distributed-tracing-console-plugin.git "${tracing_dir%/tests}"
git clone --depth 1 https://github.com/openshift/troubleshooting-panel-console-plugin.git "${panel_dir%/web}"

runSuite tracing "${tracing_dir}" npm run test-cypress-console-headless
runSuite incidents "${monitoring_dir}" npm run test-cypress-incidents

oc apply -f - <<EOF
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: troubleshooting-panel
spec:
  type: TroubleshootingPanel
EOF
runSuite troubleshooting-panel "${panel_dir}" npx cypress run --e2e --spec cypress/e2e/acceptance.cy.ts

oc create secret generic llmcreds -n "${OLS_NAMESPACE}" \
    --from-file=aws_access_key_id=/var/run/bedrock/aws_access_key_id \
    --from-file=aws_secret_access_key=/var/run/bedrock/aws_secret_access_key \
    --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<EOF
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

waitForAvailable 900 -n "${OLS_NAMESPACE}" deployment/lightspeed-app-server
runSuite ols "${monitoring_dir}" npm run test-cypress-perses-ols
exit "${result}"
