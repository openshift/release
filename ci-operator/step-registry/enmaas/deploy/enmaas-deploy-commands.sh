#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Cloning EnMaaS-opps repository (branch: ${ENMAAS_BRANCH})..."
WORK_DIR=$(mktemp -d)

# Clone EnMaaS-opps repository
ENMAAS_CREDENTIALS="/secret/enmaas/token"
if [[ -f "${ENMAAS_CREDENTIALS}" ]]; then
    echo "Configuring git credentials for private repository clone..."
    GITHUB_TOKEN=$(cat "${ENMAAS_CREDENTIALS}")
    # Configure credential helper to avoid token leakage in git remote output or shell traces
    git config --global credential.helper \
        "!f() { echo username=x-access-token; echo password=${GITHUB_TOKEN}; }; f"
    git clone "https://github.com/redhat-et/EnMaaS-opps.git" \
        --branch "${ENMAAS_BRANCH}" --depth 1 "${WORK_DIR}/EnMaaS-opps"
else
    echo "WARNING: No GitHub credentials found at ${ENMAAS_CREDENTIALS}"
    echo "Attempting unauthenticated clone (will fail for private repos)..."
    git clone "https://github.com/redhat-et/EnMaaS-opps.git" \
        --branch "${ENMAAS_BRANCH}" --depth 1 "${WORK_DIR}/EnMaaS-opps"
fi
cd "${WORK_DIR}/EnMaaS-opps"

echo "Discovering cluster app domain..."
APP_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
echo "Cluster app domain: ${APP_DOMAIN}"

echo "Patching enmaas.params with cluster-specific values..."
PARAMS_FILE="clusters/${ENMAAS_ENV}/params/enmaas.params"
if [[ -f "${PARAMS_FILE}" ]]; then
  sed -i "s|^DASHBOARD_HOST=.*|DASHBOARD_HOST=dashboard-enmaas.${APP_DOMAIN}|" "${PARAMS_FILE}"
  sed -i "s|^GATEWAY_HOST=.*|GATEWAY_HOST=gateway-enmaas.${APP_DOMAIN}|" "${PARAMS_FILE}"
  sed -i "s|^GATEWAY_URL=.*|GATEWAY_URL=https://gateway-enmaas.${APP_DOMAIN}|" "${PARAMS_FILE}"
  sed -i "s|^WELCOME_DASHBOARD_URL=.*|WELCOME_DASHBOARD_URL=https://dashboard-enmaas.${APP_DOMAIN}/welcome|" "${PARAMS_FILE}"
  # Override node selector for CI (stage uses dedicated enmaas=true nodes that don't exist in CI)
  sed -i 's|^NODE_LABEL_KEY=.*|NODE_LABEL_KEY=kubernetes.io/os|' "${PARAMS_FILE}"
  sed -i 's|^NODE_LABEL_VALUE=.*|NODE_LABEL_VALUE=linux|' "${PARAMS_FILE}"
  echo "Parameters patched successfully."
else
  echo "WARNING: ${PARAMS_FILE} not found, skipping parameter patching."
fi

# If RDS connection details are available in SHARED_DIR (written by
# enmaas-provision-rds), build a connection URL and update params to point
# to the external RDS instance instead of the in-cluster CloudNativePG database.
if [[ -f "${SHARED_DIR}/rds-endpoint" ]]; then
  echo "External RDS detected, configuring database connection..."

  RDS_HOST=$(cat "${SHARED_DIR}/rds-endpoint")
  RDS_PORT=$(cat "${SHARED_DIR}/rds-port")
  RDS_USER=$(cat "${SHARED_DIR}/rds-username")
  RDS_DBNAME=$(cat "${SHARED_DIR}/rds-dbname")

  # Disable tracing due to password handling
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  RDS_PASS=$(cat "${SHARED_DIR}/rds-password")
  DB_URL="postgresql://${RDS_USER}:${RDS_PASS}@${RDS_HOST}:5432/${RDS_DBNAME}?sslmode=require"
  $WAS_TRACING && set -x

  echo "RDS connection URL built."

  # Update params to use external database if the params file supports it
  if [[ -f "${PARAMS_FILE}" ]]; then
    # Point EnMaaS to the external RDS PostgreSQL instance
    if grep -q '^DB_HOST=' "${PARAMS_FILE}"; then
      sed -i "s|^DB_HOST=.*|DB_HOST=${RDS_HOST}|" "${PARAMS_FILE}"
      echo "Params updated: DB_HOST=${RDS_HOST}"
    else
      echo "WARNING: DB_HOST key not found in ${PARAMS_FILE}, skipping."
    fi
    if grep -q '^DB_PORT=' "${PARAMS_FILE}"; then
      sed -i "s|^DB_PORT=.*|DB_PORT=${RDS_PORT}|" "${PARAMS_FILE}"
      echo "Params updated: DB_PORT=${RDS_PORT}"
    else
      echo "WARNING: DB_PORT key not found in ${PARAMS_FILE}, skipping."
    fi
    if grep -q '^DB_NAME=' "${PARAMS_FILE}"; then
      sed -i "s|^DB_NAME=.*|DB_NAME=${RDS_DBNAME}|" "${PARAMS_FILE}"
      echo "Params updated: DB_NAME=${RDS_DBNAME}"
    else
      echo "WARNING: DB_NAME key not found in ${PARAMS_FILE}, skipping."
    fi
  fi
else
  echo "No external RDS configured, using in-cluster database."
fi

echo "Creating namespaces..."
oc create namespace enmaas --dry-run=client -o yaml | oc apply -f -
oc create namespace enmaas-monitoring --dry-run=client -o yaml | oc apply -f -
oc apply -f base/projects/enmaas/namespace.yaml
oc apply -f base/projects/enmaas-monitoring/00-namespace.yaml

echo "Creating enmaas-monitoring secrets..."
oc -n enmaas-monitoring create secret generic grafana-oauth-cookie \
  --from-literal=session_secret="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas-monitoring create secret generic alertmanager-oauth-cookie \
  --from-literal=session_secret="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas-monitoring create secret generic prometheus-oauth-cookie \
  --from-literal=session_secret="$(openssl rand -base64 24)" \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas-monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password=admin \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas-monitoring create secret generic grafana-oauth-github \
  --from-literal=client-id=dummy-client-id \
  --from-literal=client-secret=dummy-client-secret \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas-monitoring create secret generic alertmanager-slack \
  --from-literal=slack_api_url=https://hooks.slack.com/services/dummy/dummy/dummy \
  --dry-run=client -o yaml | oc apply -f -
echo "enmaas-monitoring secrets created."

echo "Creating enmaas secrets..."
# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
if [[ -n "${DB_URL:-}" ]]; then
  oc -n enmaas create secret generic postgresql-credentials \
    --from-literal=METERING_DB_URL="${DB_URL}" \
    --dry-run=client -o yaml | oc apply -f -
  oc -n enmaas create secret generic metering-readonly-db-url \
    --from-literal=READ_DATABASE_URL="${DB_URL}" \
    --dry-run=client -o yaml | oc apply -f -
  oc -n enmaas create secret generic maas-db-config \
    --from-literal=DB_CONNECTION_URL="${DB_URL}" \
    --dry-run=client -o yaml | oc apply -f -
fi
$WAS_TRACING && set -x
oc -n enmaas create secret generic provider-credentials \
  --from-literal=ANTHROPIC_API_KEY=dummy-key \
  --from-literal=CB_LITELLM_API_KEY=dummy-key \
  --from-literal=LITELLM_API_KEY=dummy-key \
  --from-literal=OPENAI_API_KEY=dummy-key \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas create secret generic pricetag-session \
  --from-literal=SESSION_SECRET="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas create secret generic metering-internal-auth \
  --from-literal=token="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas create secret generic vertex-sa-key \
  --from-literal=sa-key.json='{"type":"service_account","project_id":"dummy","private_key_id":"dummy","private_key":"dummy","client_email":"dummy@dummy.iam.gserviceaccount.com","client_id":"0","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}' \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas create secret generic metering-partner-api \
  --from-literal=model-catalog=dummy \
  --from-literal=model-catalog-aibt=dummy \
  --from-literal=model-policy=dummy \
  --from-literal=model-policy-aibt=dummy \
  --from-literal=usage-report=dummy \
  --from-literal=usage-report-aibt=dummy \
  --from-literal=usage-report-air=dummy \
  --dry-run=client -o yaml | oc apply -f -
oc -n enmaas create secret generic metering-user-management-api \
  --from-literal=token="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | oc apply -f -
echo "enmaas secrets created."

echo "Rendering and applying enmaas manifests..."
make print ENV="${ENMAAS_ENV}" PROJECT=enmaas > /tmp/enmaas.yaml
oc apply -f /tmp/enmaas.yaml

echo "Rendering and applying enmaas-monitoring manifests..."
make print ENV="${ENMAAS_ENV}" PROJECT=enmaas-monitoring > /tmp/enmaas-monitoring.yaml
oc apply --server-side --field-manager=enmaas-opps --force-conflicts -f /tmp/enmaas-monitoring.yaml

echo "Patching NetworkPolicy for API server access..."
API_IPS=$(oc get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[*].ip}')
if [[ -z "${API_IPS}" ]]; then
  echo "WARNING: Could not determine API server IPs, skipping NetworkPolicy creation"
else
  # Build the to: list from API server IPs
  TO_ENTRIES=""
  for ip in ${API_IPS}; do
    TO_ENTRIES="${TO_ENTRIES}
    - ipBlock:
        cidr: ${ip}/32"
  done

  cat <<EOF | oc apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: enmaas-allow-api-server-egress
  namespace: enmaas
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:${TO_ENTRIES}
    ports:
    - protocol: TCP
      port: 443
    - protocol: TCP
      port: 6443
EOF
  echo "NetworkPolicy enmaas-allow-api-server-egress created."
fi

echo "EnMaaS deployment applied successfully."
