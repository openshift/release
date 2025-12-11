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

# Debug wait timeout - can be set via environment variable (in seconds)
# Default: 0 (no wait). Set to a positive number to wait for debugging.
DEBUG_WAIT_TIMEOUT="${DEBUG_WAIT_TIMEOUT:-0}"

# Function to gather comprehensive debugging information
gather_debug_info() {
    local operator_name=$1
    local operator_install_namespace=$2
    local operator_source=$3
    
    echo "=========================================="
    echo "DEBUG: Gathering diagnostic information for ${operator_name}"
    echo "=========================================="
    
    # Cluster version
    echo "--- OpenShift Cluster Version ---"
    oc version -o yaml || echo "Failed to get cluster version"
    echo ""
    
    # Operator namespace
    echo "--- Namespace ${operator_install_namespace} ---"
    oc get namespace "${operator_install_namespace}" -o yaml || echo "Namespace not found"
    echo ""
    
    # OperatorGroup
    echo "--- OperatorGroups in ${operator_install_namespace} ---"
    oc get operatorgroup -n "${operator_install_namespace}" -o yaml || echo "No OperatorGroups found"
    echo ""
    
    # Subscription
    echo "--- Subscription ${operator_name} ---"
    oc get subscription "${operator_name}" -n "${operator_install_namespace}" -o yaml || echo "Subscription not found"
    echo ""
    
    # Subscription conditions
    echo "--- Subscription Conditions ---"
    oc get subscription "${operator_name}" -n "${operator_install_namespace}" -o jsonpath='{.status.conditions[*]}' | jq -r '.' 2>/dev/null || \
        oc get subscription "${operator_name}" -n "${operator_install_namespace}" -o jsonpath='{.status.conditions[*]}' || echo "No conditions found"
    echo ""
    
    # InstallPlans
    echo "--- InstallPlans in ${operator_install_namespace} ---"
    oc get installplan -n "${operator_install_namespace}" -o yaml || echo "No InstallPlans found"
    echo ""
    
    # CSVs
    echo "--- ClusterServiceVersions in ${operator_install_namespace} ---"
    oc get csv -n "${operator_install_namespace}" -o yaml || echo "No CSVs found"
    echo ""
    
    # CSV status if exists
    local csv_name=$(oc get subscription "${operator_name}" -n "${operator_install_namespace}" -o jsonpath='{.status.installedCSV}' 2>/dev/null || echo "")
    if [[ -n "${csv_name}" ]]; then
        echo "--- CSV ${csv_name} Details ---"
        oc get csv "${csv_name}" -n "${operator_install_namespace}" -o yaml || echo "CSV not found"
        echo ""
        echo "--- CSV ${csv_name} Status ---"
        oc describe csv "${csv_name}" -n "${operator_install_namespace}" || echo "Failed to describe CSV"
        echo ""
    fi
    
    # CatalogSource
    echo "--- CatalogSource ${operator_source} ---"
    oc get catalogsource "${operator_source}" -n openshift-marketplace -o yaml || echo "CatalogSource not found"
    echo ""
    
    # All CatalogSources
    echo "--- All CatalogSources in openshift-marketplace ---"
    oc get catalogsource -n openshift-marketplace -o yaml || echo "No CatalogSources found"
    echo ""
    
    # PackageManifest
    echo "--- PackageManifest ${operator_name} ---"
    oc get packagemanifest "${operator_name}" -o yaml || echo "PackageManifest not found"
    echo ""
    
    # All PackageManifests for this operator
    echo "--- All PackageManifests matching ${operator_name} ---"
    oc get packagemanifest | grep "${operator_name}" || echo "No PackageManifests found"
    echo ""
    
    # Pods in namespace
    echo "--- Pods in ${operator_install_namespace} ---"
    oc get pods -n "${operator_install_namespace}" -o yaml || echo "No pods found"
    echo ""
    
    # Events in namespace
    echo "--- Events in ${operator_install_namespace} ---"
    oc get events -n "${operator_install_namespace}" --sort-by='.lastTimestamp' || echo "No events found"
    echo ""
    
    # OLM operator logs (if available)
    echo "--- OLM Operator Logs (last 50 lines) ---"
    oc logs -n openshift-operator-lifecycle-manager -l app=olm-operator --tail=50 || echo "Could not retrieve OLM logs"
    echo ""
    
    echo "=========================================="
    echo "DEBUG: Diagnostic information gathering complete"
    echo "=========================================="
}

# If not provided in the JSON, will use the following defaults.
DEFAULT_OPERATOR_SOURCE="redhat-operators"
DEFAULT_OPERATOR_SOURCE_DISPLAY="Red Hat Operators"
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
    operator_config=$(jq --raw-output '.config // ""' <<< "$operator_obj")
    operator_skip_checking=$(jq --raw-output '.skip_checking// ""' <<< "$operator_obj")

    # If name not defined, exit.
    if [[ -z "${operator_name}" ]]; then
        echo "ERROR: name is not defined"
        exit 1
    fi

    # If source is not defined, use DEFAULT_OPERATOR_SOURCE.
    if [[ -z "${operator_source}" ]]; then
        operator_source="${DEFAULT_OPERATOR_SOURCE}"
    else
        # If source is any, use any available catalog
        if [[ "${operator_source}" == "!any" ]]; then
            # Prioritize the use of the default catalog
            operator_source=$(oc get packagemanifest | grep "${operator_name}.*${DEFAULT_OPERATOR_SOURCE_DISPLAY}" || echo)
            if [[ -n "${operator_source}" ]]; then
                operator_source="${DEFAULT_OPERATOR_SOURCE}" ;
            else
                operator_source=$(oc get packagemanifest ${operator_name} -ojsonpath='{.metadata.labels.catalog}' || echo)
                if [[ -z "${operator_source}" ]]; then
                    echo "ERROR: '${operator_name}' packagemanifest not found in any available catalog"
                    exit 1
                fi
            fi
            echo "Selecting '${operator_source}' catalog to install '${operator_name}'"
        fi
    fi

    # If install_namespace not defined, use DEFAULT_OPERATOR_INSTALL_NAMESPACE.
    if [[ -z "${operator_install_namespace}" ]]; then
        operator_install_namespace="${DEFAULT_OPERATOR_INSTALL_NAMESPACE}"
    fi

    # If channel is not defined, use DEFAULT_OPERATOR_CHANNEL.
    if [[ -z "${operator_channel}" ]]; then
        operator_channel="${DEFAULT_OPERATOR_CHANNEL}"
    fi

    echo "Getting '${operator_name}' packagemanifest from '${operator_channel}' channel using '${operator_source}' catalog"
    # If the channel is "!default", find the default channel of the operator
    if [[ "${operator_channel}" == "!default" ]]; then
        operator_channel=$(oc get packagemanifest \
            -l catalog=${operator_source} \
            -ojsonpath='{.items[?(.metadata.name=="'${operator_name}'")].status.defaultChannel}' 2>/dev/null || echo)
        if [[ -z "${operator_channel}" ]]; then
            echo "ERROR: Default channel not found in '${operator_name}' packagemanifest."
            echo "Checking if the ${operator_name} packagemanifest is available in other catalogs for debugging purpose:"
            set -x
            oc get packagemanifest "${operator_name}" || \
              echo "There is not any available packagemanifest for '${operator_name}' operator"
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

    echo "Creating subscription for ${operator_name} operator using ${operator_source} source"
    # Subscribe to the operator
    if [[ -z "$operator_config" ]]; then
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
    else
        cat <<EOF | oc apply -f -
        {
            "apiVersion": "operators.coreos.com/v1alpha1",
            "kind": "Subscription",
            "metadata": {
                "name": "${operator_name}",
                "namespace": "${operator_install_namespace}"
            },
            "spec": {
                "channel": "${operator_channel}",
                "installPlanApproval": "Automatic",
                "name": "${operator_name}",
                "source": "${operator_source}",
                "sourceNamespace": "openshift-marketplace",
                "config": ${operator_config}
            }
        }
EOF
    fi

    # Need to allow some time before checking if the operator is installed.
    sleep 60

    RETRIES=30
    CSV=
    for i in $(seq "${RETRIES}"); do
        if [[ -z "${CSV}" ]]; then
            CSV=$(oc get subscription -n "${operator_install_namespace}" "${operator_name}" -o jsonpath='{.status.installedCSV}')
        fi

        if [[ -z "${CSV}" ]]; then
            # Check for dependency resolution failures early
            resolution_failed=$(oc get subscription "${operator_name}" -n "${operator_install_namespace}" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].status}' 2>/dev/null || echo "")
            if [[ "${resolution_failed}" == "True" ]]; then
                echo "Try ${i}/${RETRIES}: Dependency resolution failed for ${operator_name}"
                resolution_message=$(oc get subscription "${operator_name}" -n "${operator_install_namespace}" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].message}' 2>/dev/null || echo "")
                if [[ -n "${resolution_message}" ]]; then
                    echo "Resolution error: ${resolution_message}"
                fi
                # Break early if it's a dependency issue - no point retrying
                break
            fi
            echo "Try ${i}/${RETRIES}: can't get the ${operator_name} yet. Checking again in 30 seconds"
            sleep 30
            continue
        fi

        csv_phase=$(oc get csv -n "${operator_install_namespace}" "${CSV}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "${csv_phase}" == "Succeeded" ]]; then
            echo "${operator_name} is deployed"
            break
        else
            echo "Try ${i}/${RETRIES}: ${operator_name} is not deployed yet. Checking again in 30 seconds"
            sleep 30
        fi
    done

    if [[ -z "${CSV}" ]]; then
        echo "Error: Failed to deploy ${operator_name} - CSV was never created"
        echo
        echo "Assert that the '${operator_name}' packagemanifest belongs to '${operator_source}' catalog"
        echo
        oc get packagemanifest | grep ${operator_name} || echo
        echo "Subscription details:"
        oc get subscription "${operator_name}" -n "${operator_install_namespace}" -o yaml || echo
        
        # Check for dependency resolution failures
        resolution_failed=$(oc get subscription "${operator_name}" -n "${operator_install_namespace}" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].status}' 2>/dev/null || echo "")
        if [[ "${resolution_failed}" == "True" ]]; then
            echo
            echo "⚠️  DEPENDENCY RESOLUTION FAILURE DETECTED ⚠️"
            echo "The operator subscription failed due to missing or incompatible dependencies."
            resolution_message=$(oc get subscription "${operator_name}" -n "${operator_install_namespace}" -o jsonpath='{.status.conditions[?(@.type=="ResolutionFailed")].message}' 2>/dev/null || echo "")
            if [[ -n "${resolution_message}" ]]; then
                echo "Resolution error message:"
                echo "${resolution_message}"
                echo
                echo "This usually means:"
                echo "  1. A required dependency operator is not installed"
                echo "  2. A required dependency operator version is not available"
                echo "  3. The dependency operator version does not meet the required version constraints"
                echo
                echo "Please check the error message above to identify which dependency is missing."
            fi
        fi
        
        # Gather comprehensive debug information
        gather_debug_info "${operator_name}" "${operator_install_namespace}" "${operator_source}"
        
        if [[ "${operator_skip_checking}" == "true" ]]; then
            echo "'${operator_name}' installation failed, but maybe not all needed CRDs are available yet... continue"
        else
            # Wait for debugging if DEBUG_WAIT_TIMEOUT is set
            if [[ "${DEBUG_WAIT_TIMEOUT}" -gt 0 ]]; then
                echo ""
                echo "⚠️  DEBUG WAIT: Waiting ${DEBUG_WAIT_TIMEOUT} seconds for debugging..."
                echo "   You can now access the cluster to investigate the issue."
                echo "   Cluster will remain available for ${DEBUG_WAIT_TIMEOUT} seconds."
                sleep "${DEBUG_WAIT_TIMEOUT}"
                echo "DEBUG WAIT: Timeout reached, proceeding with exit."
            fi
            exit 1
        fi
    elif [[ -n "${CSV}" ]] && [[ $(oc get csv -n "${operator_install_namespace}" "${CSV}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "") != "Succeeded" ]]; then
        echo "Error: Failed to deploy ${operator_name}"
        echo
        echo "Assert that the '${operator_name}' packagemanifest belongs to '${operator_source}' catalog"
        echo
        oc get packagemanifest | grep ${operator_name} || echo
        if [[ -n "${CSV}" ]]; then
            echo "CSV ${CSV} YAML"
            oc get csv "${CSV}" -n "${operator_install_namespace}" -o yaml || echo "Failed to get CSV ${CSV}"
            echo
            echo "CSV ${CSV} Describe"
            oc describe csv "${CSV}" -n "${operator_install_namespace}" || echo "Failed to describe CSV ${CSV}"
        else
            echo "CSV was not found in subscription"
            echo "Subscription details:"
            oc get subscription "${operator_name}" -n "${operator_install_namespace}" -o yaml || echo
        fi
        
        # Gather comprehensive debug information
        gather_debug_info "${operator_name}" "${operator_install_namespace}" "${operator_source}"
        
        if [[ "${operator_skip_checking}" == "true" ]]; then
            echo "'${operator_name}' installation failed, but maybe not all needed CRDs are available yet... continue"
        else
            # Wait for debugging if DEBUG_WAIT_TIMEOUT is set
            if [[ "${DEBUG_WAIT_TIMEOUT}" -gt 0 ]]; then
                echo ""
                echo "⚠️  DEBUG WAIT: Waiting ${DEBUG_WAIT_TIMEOUT} seconds for debugging..."
                echo "   You can now access the cluster to investigate the issue."
                echo "   Cluster will remain available for ${DEBUG_WAIT_TIMEOUT} seconds."
                sleep "${DEBUG_WAIT_TIMEOUT}"
                echo "DEBUG WAIT: Timeout reached, proceeding with exit."
            fi
            exit 1
        fi
    else
        echo "Successfully installed ${operator_name}"
    fi
done
