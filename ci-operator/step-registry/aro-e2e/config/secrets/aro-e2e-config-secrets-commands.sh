#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function login {
  chmod +x ${SHARED_DIR}/azure-login.sh
  source ${SHARED_DIR}/azure-login.sh
}

function secrets {

  test -f "${CLUSTER_PROFILE_DIR}/secret_sa_account_name" || echo "secret_sa_account_name is missing in cluster profile"
  SECRET_SA_ACCOUNT_NAME="$(<"${CLUSTER_PROFILE_DIR}/secret_sa_account_name")"

  az storage blob download -n secrets.tar.gz -c secrets -f secrets.tar.gz --account-name ${SECRET_SA_ACCOUNT_NAME} >/dev/null
  tar -xzf secrets.tar.gz
  rm secrets.tar.gz
  mv secrets/* "${SHARED_DIR}/"
}

# for saving files...
cd /tmp

login
secrets
