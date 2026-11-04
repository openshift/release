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
PARAMS_FILE="clusters/${ENMAAS_ENV}/enmaas/enmaas.params"
if [[ -f "${PARAMS_FILE}" ]]; then
  sed -i "s|^DASHBOARD_HOST=.*|DASHBOARD_HOST=dashboard-enmaas.${APP_DOMAIN}|" "${PARAMS_FILE}"
  sed -i "s|^GATEWAY_HOST=.*|GATEWAY_HOST=gateway-enmaas.${APP_DOMAIN}|" "${PARAMS_FILE}"
  sed -i "s|^GATEWAY_URL=.*|GATEWAY_URL=https://gateway-enmaas.${APP_DOMAIN}|" "${PARAMS_FILE}"
  sed -i "s|^WELCOME_DASHBOARD_URL=.*|WELCOME_DASHBOARD_URL=https://dashboard-enmaas.${APP_DOMAIN}/welcome|" "${PARAMS_FILE}"
  echo "Parameters patched successfully."
else
  echo "WARNING: ${PARAMS_FILE} not found, skipping parameter patching."
fi

# If RDS connection details are available in SHARED_DIR (written by
# enmaas-provision-rds), create a Kubernetes secret with the database
# credentials and update the params to point to the external RDS instance
# instead of the in-cluster CloudNativePG database.
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

  # The secret follows the structure expected by EnMaaS for external database
  # configuration: host, port, username, password, and dbname as individual keys.
  oc create namespace enmaas --dry-run=client -o yaml | oc apply -f -
  oc -n enmaas create secret generic enmaas-rds-credentials \
    --from-literal=host="${RDS_HOST}" \
    --from-literal=port="${RDS_PORT}" \
    --from-literal=username="${RDS_USER}" \
    --from-literal=password="${RDS_PASS}" \
    --from-literal=dbname="${RDS_DBNAME}" \
    --dry-run=client -o yaml | oc apply -f -
  $WAS_TRACING && set -x

  echo "RDS credentials secret created in enmaas namespace."

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
oc apply -f base/projects/enmaas/namespace.yaml
oc apply -f base/projects/enmaas-monitoring/00-namespace.yaml

# Secrets need to be provided via CI credential volumes mounted into $SHARED_DIR.
# To add secrets, configure credential volumes in the ci-operator config and
# create the required secret resources from files in $SHARED_DIR here.
# Example:
#   if [[ -f "${SHARED_DIR}/enmaas-secret.yaml" ]]; then
#     oc apply -f "${SHARED_DIR}/enmaas-secret.yaml"
#   fi
echo "NOTE: Secrets should be provided via CI credential volumes in SHARED_DIR."

echo "Rendering and applying enmaas manifests..."
make print ENV="${ENMAAS_ENV}" PROJECT=enmaas > /tmp/enmaas.yaml
oc apply -f /tmp/enmaas.yaml

echo "Rendering and applying enmaas-monitoring manifests..."
make print ENV="${ENMAAS_ENV}" PROJECT=enmaas-monitoring > /tmp/enmaas-monitoring.yaml
oc apply --server-side --field-manager=enmaas-opps --force-conflicts -f /tmp/enmaas-monitoring.yaml

echo "EnMaaS deployment applied successfully."
