#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

CREDENTIALS_DIR="/var/run/${TENANT_ID}"
if [[ ! -d "${CREDENTIALS_DIR}" ]]; then
  echo "Credentials directory '${CREDENTIALS_DIR}' does not exist." >&2
  exit 1
fi


CLIENT_ID=$(cat "${CREDENTIALS_DIR}/client-id")
CLIENT_SECRET=$(cat "${CREDENTIALS_DIR}/client-secret")
TENANT_ID=$(cat "${CREDENTIALS_DIR}/tenant")

cat > "${SHARED_DIR}/az-login.sh" <<EOF
#!/bin/bash
set -euo pipefail
az login --service-principal -u '${CLIENT_ID}' -p '${CLIENT_SECRET}' --tenant '${TENANT_ID}' --output none
az account set --subscription "\${SUBSCRIPTION}"
EOF

chmod +x "${SHARED_DIR}/az-login.sh"
