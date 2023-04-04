#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# shellcheck source=/dev/null
source "${SHARED_DIR}/install-env"
extract_opct

# Retrieve after successful execution
mkdir -p "${ARTIFACT_DIR}/certification-results"
${OPCT_EXEC} retrieve "${ARTIFACT_DIR}/certification-results"

# Run results summary (to log to file)
${OPCT_EXEC} results "${ARTIFACT_DIR}"/certification-results/*.tar.gz

# Run report (to log to file)
${OPCT_EXEC} report --verbose "${ARTIFACT_DIR}"/certification-results/*.tar.gz

#
# Gather some cluster information and upload certification results
#
export AWS_DEFAULT_REGION=us-west-2
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/opct/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

# Install AWS CLI
if ! command -v aws &> /dev/null
then
    echo "$(date -u --rfc-3339=seconds) - Install AWS cli..."
    export PATH="${HOME}/.local/bin:${PATH}"
    if command -v pip3 &> /dev/null
    then
        pip3 install --user awscli
    else
        if [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 2 ]
        then
          easy_install --user 'pip<21'
          pip install --user awscli
        else
          echo "$(date -u --rfc-3339=seconds) - No pip available exiting..."
          exit 1
        fi
    fi
fi

# install newest oc
# export PATH=$PATH:/tmp/bin
# mkdir /tmp/bin
# curl -L --fail https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz | tar xvzf - -C /tmp/bin/ oc
# chmod ug+x /tmp/bin/oc
# export KUBECONFIG=${SHARED_DIR}/kubeconfig
OCP_VERSION=$(oc get clusterversion version -o=jsonpath='{.status.desired.version}')

# upload to AWS S3
DATE=$(date +%Y%m%d)

# shellcheck disable=SC2153 # OPCT_VERSION is defined on ${SHARED_DIR}/install-env
echo "s3://openshift-provider-certification/${OPCT_VERSION}/${OCP_VERSION}-${DATE}.tar.gz"
echo '{"platform-type":"'"${CLUSTER_TYPE}"'"}'

aws s3 cp "${ARTIFACT_DIR}"/certification-results/*.tar.gz \
  "s3://openshift-provider-certification/${OPCT_VERSION}/${OCP_VERSION}-${DATE}.tar.gz" \
  --metadata '{"platform-type":"'"${CLUSTER_TYPE}"'"}'
