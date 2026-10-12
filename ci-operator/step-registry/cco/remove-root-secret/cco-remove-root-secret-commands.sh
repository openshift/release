#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail


if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig

function remove_root_secret()
{
    local secret_name=$1
    echo "Removing secret ${secret_name} from kube-system"
    oc delete secret -n kube-system ${secret_name} || return 1
    echo "Removed."

}

mode=$(oc get cloudcredentials cluster -o=jsonpath="{.spec.credentialsMode}")

echo "credential mode: ${mode}"
case "${CLUSTER_TYPE:-}" in
aws|aws-arm64|aws-usgov)
    if [[ ${mode} == "" ]] || [[ ${mode} == "Mint" ]]; then
        remove_root_secret "aws-creds"
    else
        echo "Removing root secret in credentialsMode \"${mode}\" on AWS is not supported. exit now."
        exit 1
    fi
    ;;
gcp)
    # TODO: check default credentialsMode on GCP
    # remove_root_secret "aws-creds"
    exit 1
    ;;
*)
    echo "Cluster type '${CLUSTER_TYPE}' is not supported, exit now."
    exit 1
esac
