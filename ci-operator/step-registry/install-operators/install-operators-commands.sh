#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set the cluster proxy configuration, if its present.
if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
    echo "setting the proxy"
    echo "source ${SHARED_DIR}/proxy-conf.sh"
    source "${SHARED_DIR}/proxy-conf.sh"
else
    echo "no proxy setting."
fi

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
    operator_install_namespace=$(jq --raw-output '.install_namespace // ""' <<< "$operator_obj")
    operator_group=$(jq --raw-output '.operator_group // ""' <<< "$operator_obj")
    operator_target_namespaces=$(jq --raw-output '.target_namespaces // ""' <<< "$operator_obj")

    # If name not defined, exit.
    if [[ -z "${operator_name}" ]]; then
        echo "ERROR: name is not defined"
        exit 1
    fi

    # If source is not defined, use DEFAULT_OPERATOR_SOURCE.
    if [[ -z "${operator_source}" ]]; then
        operator_source="${DEFAULT_OPERATOR_SOURCE}"
    fi

    # If install_namespace not defined, use DEFAULT_OPERATOR_INSTALL_NAMESPACE.
    if [[ -z "${operator_install_namespace}" ]]; then
        operator_install_namespace="${DEFAULT_OPERATOR_INSTALL_NAMESPACE}"
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

    # If "!install" in target_namespaces, use the install namespace
    if [[ "${operator_target_namespaces}" == "!install" ]]; then
        operator_target_namespaces="${operator_install_namespace}"
    fi
    
    echo "Installing ${operator_name} from ${operator_source} channel ${operator_channel} into ${operator_install_namespace}${operator_target_namespaces:+, targeting $operator_target_namespaces}"

    # Create the install namespace
    oc apply -f - <<EOF
    apiVersion: v1
    kind: Namespace
    metadata:
        labels:
          openshift.io/cluster-monitoring: "true"
        name: "${operator_install_namespace}"
EOF

    # Deploy new operator group if operator group is defined
    if [[ -n "$operator_group" ]]; then
        if [[ -z "$operator_target_namespaces" ]]; then
            echo "Deploying OperatorGroup ${operator_group} in to ${operator_install_namespace}"
            oc apply -f - <<EOF
            apiVersion: operators.coreos.com/v1
            kind: OperatorGroup
            metadata:
                name: "${operator_group}"
                namespace: "${operator_install_namespace}"
            installModes:
                - supported: true
                  type: AllNamespaces    
EOF
        else
            echo "Deploying OperatorGroup ${operator_group} in to ${operator_install_namespace} with target namespaces: ${operator_target_namespaces}"
            oc apply -f - <<EOF
            apiVersion: operators.coreos.com/v1
            kind: OperatorGroup
            metadata:
                name: "${operator_group}"
                namespace: "${operator_install_namespace}"
            spec:
                targetNamespaces:
                - $(echo \"${operator_target_namespaces}\" | sed "s|,|\"\n  - \"|g")
EOF
        fi
    fi

    # Subscribe to the operator
    cat <<EOF | oc apply -f -
    apiVersion: operators.coreos.com/v1alpha1
    kind: Subscription
    metadata:
        name: "${operator_name}"
        namespace: "${operator_install_namespace}"
    spec:
        channel: "${operator_channel}"
        installPlanApproval: Automatic
        name: "${operator_name}"
        source: "${operator_source}"
        sourceNamespace: openshift-marketplace
EOF

    # Need to allow some time before checking if the operator is installed.
    sleep 60

    RETRIES=30
    CSV=
    for i in $(seq "${RETRIES}"); do
        if [[ -z "${CSV}" ]]; then
            CSV=$(oc get subscription -n "${operator_install_namespace}" "${operator_name}" -o jsonpath='{.status.installedCSV}')
        fi

        if [[ -z "${CSV}" ]]; then
            echo "Try ${i}/${RETRIES}: can't get the ${operator_name} yet. Checking again in 30 seconds"
            sleep 30
        fi

        if [[ $(oc get csv -n ${operator_install_namespace} ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
            echo "${operator_name} is deployed"
            break
        else
            echo "Try ${i}/${RETRIES}: ${operator_name} is not deployed yet. Checking again in 30 seconds"
            sleep 30
        fi
    done

    if [[ $(oc get csv -n "${operator_install_namespace}" "${CSV}" -o jsonpath='{.status.phase}') != "Succeeded" ]]; then
        echo "Error: Failed to deploy ${operator_name}"
        echo "CSV ${CSV} YAML"
        oc get CSV "${CSV}" -n "${operator_install_namespace}" -o yaml
        echo
        echo "CSV ${CSV} Describe"
        oc describe CSV "${CSV}" -n "${operator_install_namespace}"
        exit 1
    fi

    echo "Successfully installed ${operator_name}"

done
