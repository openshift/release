#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
INFRA_ID="$(jq -r .infraID ${SHARED_DIR}/metadata.json)"
echo "INFO: cluster name '${CLUSTER_NAME}', infra id '${INFRA_ID}'."

GOOGLE_PROJECT_ID="$(< ${CLUSTER_PROFILE_DIR}/openshift_gcp_project)"
export GCP_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/gce.json"
sa_email=$(jq -r .client_email ${GCP_SHARED_CREDENTIALS_FILE})
if ! gcloud auth list | grep -E "\*\s+${sa_email}"
then
  gcloud auth activate-service-account --key-file="${GCP_SHARED_CREDENTIALS_FILE}"
  gcloud config set project "${GOOGLE_PROJECT_ID}"
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

ret=0

echo "INFO: Checking cluster credentials mode..."

curr_credentials_mode=$(oc get cloudcredential cluster -o json | jq -r ".spec.credentialsMode")
if [ -z "${curr_credentials_mode}" ]; then
    curr_credentials_mode="Mint"
fi
echo "INFO: Current credentials mode: '${curr_credentials_mode}'"

expected_credentials_mode=""
if [ -n "${CREDENTIALS_MODE}" ]; then
    expected_credentials_mode="${CREDENTIALS_MODE}"
elif test -f "${SHARED_DIR}/install-config.yaml"; then
    expected_credentials_mode=$(yq-go r "${SHARED_DIR}/install-config.yaml" credentialsMode)
fi
if [ -z "${expected_credentials_mode}" ]; then
    echo "INFO: empty expected credentials mode, setting it to 'Mint'..."
    expected_credentials_mode="Mint"
fi
echo "INFO: The expected credentials mode: '${expected_credentials_mode}'"

if [[ "${curr_credentials_mode}" == "${expected_credentials_mode}" ]]; then
    echo "INFO: Cluster credentials mode check passed."
else
    echo "ERROR: Cluster credentials mode check failed."
    ret=$(( $ret | 1 ))
fi

if [[ "${curr_credentials_mode}" == "Passthrough" ]]; then
    echo "INFO: Cluster credentials mode is 'Passthrough', checking the IAM service-accounts..."
    echo "INFO: Expecting 1-2 IAM service-account(s), and one for compute nodes, another for control-plane nodes."
    readarray -t iam_accounts < <(gcloud iam service-accounts list --filter="displayName~${CLUSTER_NAME}" --format="table(email)" | grep -v EMAIL)
    total_count=0; matched_count=0
    for iam_account in "${iam_accounts[@]}";
    do
        total_count=$(( $total_count + 1 ))
        if [[ "${iam_account}" =~ ${INFRA_ID}-[wm]\@.+\.iam\.gserviceaccount\.com ]]; then
            matched_count=$(( $matched_count + 1 ))
        fi
        echo "INFO: No. ${total_count} - '${iam_account}'"
    done
    if [ $total_count -le 2 ] && [ $total_count -eq $matched_count ]; then
        echo "INFO: IAM service-accounts check passed."
    else
        echo "ERROR: IAM service-accounts check failed."
        ret=$(( $ret | 2 ))
    fi
fi

echo "Exit code '$ret'"
exit $ret