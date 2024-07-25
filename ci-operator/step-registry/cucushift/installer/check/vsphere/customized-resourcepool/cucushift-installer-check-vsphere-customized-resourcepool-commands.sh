#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
export KUBECONFIG=${SHARED_DIR}/kubeconfig
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS
check_result=1

exit ${check_result}

