#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# If not provided in the JSON, will use the following defaults.
DEFAULT_OPERATOR_SOURCE="redhat-operators"
DEFAULT_OPERATOR_CHANNEL="!default"
DEFAULT_OPERATOR_INSTALL_NAMESPACE="openshift-operators"

# Read each operator in the JSON provided to an item in a BASH array.
readarray -t OPERATOR_ARRAY < <(jq --compact-output '.[]' <<< "$OPERATORS")

# Iterate through each operator.
for operator_obj in "${OPERATOR_ARRAY[@]}"; do
    # Set variables for this operator.
    operator_name=$(jq --raw-output '.name' <<< "$operator_obj")
    operator_source=$(jq --raw-output '.source // ""' <<< "$operator_obj")
    operator_channel=$(jq --raw-output '.channel // ""' <<< "$operator_obj")

    # If name not defined, exit.
    if [[ -z "${operator_name}" ]]; then
        echo "ERROR: name is not defined"
        exit 1
    fi

    # If source is not defined, use DEFAULT_OPERATOR_SOURCE.
    if [[ -z "${operator_source}" ]]; then
        operator_source="${DEFAULT_OPERATOR_SOURCE}"
    fi

    # If channel is not defined, use DEFAULT_OPERATOR_CHANNEL.
    if [[ -z "${operator_channel}" ]]; then
        operator_channel="${DEFAULT_OPERATOR_CHANNEL}"
    fi

    # If the channel is "!default", find the default channel of the operator
    if [[ "${operator_channel}" == "!default" ]]; then
        operator_channel=$(oc get packagemanifest "${operator_name}" -o jsonpath='{.status.defaultChannel}')
        if [[ -z "${operator_channel}" ]]; then
            echo "ERROR: Default channel not found."
            exit 1
        else
            echo "INFO: Default channel is ${operator_channel}"
        fi
    fi

    is_available=$(oc get packagemanifest -l catalog=${operator_source} -ojson |jq -c '.items[] | select(.metadata.name | contains("advanced-cluster-management"))' |jq -rc '.status.channels[] | "\(.name):\(.currentCSV)"')
    if [[ -z "${is_available}" ]]; then
        echo "ERROR: Default channel not found."
        exit 1
    fi
    echo "Installing ${operator_name} from ${operator_source} channel ${operator_channel} into ${operator_install_namespace}${operator_target_namespaces:+, targeting $operator_target_namespaces}"

done
