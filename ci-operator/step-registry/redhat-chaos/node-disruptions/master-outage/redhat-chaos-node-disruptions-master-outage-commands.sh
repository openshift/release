#!/bin/bash
set -o errexit

console_url=$(oc get routes -n openshift-console console -o jsonpath='{.spec.host}')
export HEALTH_CHECK_URL=https://$console_url
set -o nounset
set -o pipefail
set -x


ES_PASSWORD=$(cat "/secret/es/password")
ES_USERNAME=$(cat "/secret/es/username")
export ES_PASSWORD
export ES_USERNAME

export ES_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config
export KRKN_KUBE_CONFIG=$KUBECONFIG

# read passwords from vault
telemetry_password=$(cat "/secret/telemetry/telemetry_password")

# set the secrets from the vault as env vars
export TELEMETRY_PASSWORD=$telemetry_password

platform=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}') 
if [ "$platform" = "AWS" ]; then
    mkdir -p $HOME/.aws
    cat ${CLUSTER_PROFILE_DIR}/.awscred > $HOME/.aws/config
    export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
    aws_region=${REGION:-$LEASED_RESOURCE}
    export AWS_DEFAULT_REGION=$aws_region
elif [ "$platform" = "GCP" ]; then
    export CLOUD_TYPE="gcp"
    export GCP_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/gce.json
    export GOOGLE_APPLICATION_CREDENTIALS="${GCP_SHARED_CREDENTIALS_FILE}"
elif [ "$platform" = "Azure" ]; then
    export CLOUD_TYPE="azure"
    export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
    # jq is not available in the ci image...
    AZURE_SUBSCRIPTION_ID="$(jq -r .subscriptionId ${AZURE_AUTH_LOCATION})"
    export AZURE_SUBSCRIPTION_ID
    AZURE_TENANT_ID="$(jq -r .tenantId ${AZURE_AUTH_LOCATION})"
    export AZURE_TENANT_ID
    AZURE_CLIENT_ID="$(jq -r .clientId ${AZURE_AUTH_LOCATION})"
    export AZURE_CLIENT_ID
    AZURE_CLIENT_SECRET="$(jq -r .clientSecret ${AZURE_AUTH_LOCATION})"
    export AZURE_CLIENT_SECRET
elif [ "$platform" = "IBMCloud" ]; then
# https://github.com/openshift/release/blob/3afc9cb376776ca27fbb1a4927281e84295f4810/ci-operator/step-registry/openshift-extended/upgrade/pre/openshift-extended-upgrade-pre-commands.sh#L158
    IBMCLOUD_CLI=ibmcloud
    export IBMCLOUD_CLI
    IBMCLOUD_HOME=/output
    export IBMCLOUD_HOME
    region="${LEASED_RESOURCE}"
    CLOUD_TYPE="ibmcloud"
    export CLOUD_TYPE
    export region
    IBMC_URL="https://${region}.iaas.cloud.ibm.com/v1"
    export IBMC_URL
    IBMC_APIKEY=$(cat ${CLUSTER_PROFILE_DIR}/ibmcloud-api-key)
    export IBMC_APIKEY
    NODE_NAME=$(oc get nodes -l $LABEL_SELECTOR --no-headers | head -1 | awk '{printf $1}' )
    export NODE_NAME
    export TIMEOUT=320
elif [ "$platform" = "VSphere" ]; then
    export CLOUD_TYPE="vsphere"
    VSPHERE_IP=$(oc get infrastructures.config.openshift.io cluster -o jsonpath='{.spec.platformSpec.vsphere.vcenters[0].server}')
    export VSPHERE_IP
    VSPHERE_IP_WITHOUTDOT=$(echo "$VSPHERE_IP" | sed 's/\./\\./g')
    jsonpath_username="{.data.${VSPHERE_IP_WITHOUTDOT}\.username}"
    jsonpath_password="{.data.${VSPHERE_IP_WITHOUTDOT}\.password}"
    VSPHERE_USERNAME=$(oc get secret vsphere-creds -n kube-system -o jsonpath="$jsonpath_username" | base64 --decode)
    export VSPHERE_USERNAME
    VSPHERE_PASSWORD=$(oc get secret vsphere-creds -n kube-system -o jsonpath="$jsonpath_password" | base64 --decode)
    export VSPHERE_PASSWORD
elif [ "$platform" = "None" ] || [ "$platform" = "bm" ] || [ "$platform" = "baremetal" ]; then
    # Get a node that matches the LABEL_SELECTOR using oc command
    target_node=$(oc get nodes -l "${LABEL_SELECTOR}" --no-headers | head -1 | awk '{print $1}')
    
    echo "Target node for baremetal testing: ${target_node}"
    
    # Extract BMC credentials from hosts.yaml for the target node
    if [ -f "${SHARED_DIR}/hosts.yaml" ] && [ -n "$target_node" ]; then
        echo "Found hosts.yaml, extracting BMC credentials..."
        for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
            # shellcheck disable=SC1090
            . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
            
            if [[ "${target_node}" == "${name}"* ]]; then
                # shellcheck disable=SC2154
                export BMC_USER="${bmc_user}"
                # shellcheck disable=SC2154
                export BMC_PASSWORD="${bmc_pass}"
                # shellcheck disable=SC2154
                export BMC_ADDR="${bmc_scheme}://${bmc_address}${bmc_base_uri}"
                # shellcheck disable=SC2154
                export NODE_NAME="${target_node}"
                
                # Install ipmitool if not available (required for baremetal operations)
                if ! command -v ipmitool >/dev/null 2>&1; then
                    echo "Installing ipmitool for baremetal operations..."
                    if command -v yum >/dev/null 2>&1; then
                        yum install -y OpenIPMI-tools || {
                            echo "ERROR: Failed to install OpenIPMI-tools via yum"
                            exit 1
                        }
                    elif command -v apt-get >/dev/null 2>&1; then
                        apt-get update && apt-get install -y ipmitool || {
                            echo "ERROR: Failed to install ipmitool via apt-get"
                            exit 1
                        }
                    elif command -v dnf >/dev/null 2>&1; then
                        dnf install -y OpenIPMI-tools || {
                            echo "ERROR: Failed to install OpenIPMI-tools via dnf"
                            exit 1
                        }
                    else
                        echo "ERROR: Cannot install ipmitool - no supported package manager found"
                        echo "Supported package managers: yum, apt-get, dnf"
                        exit 1
                    fi
                    echo "ipmitool installed successfully"
                else
                    echo "ipmitool already available"
                fi
                
                break
            fi
        done
    else
        echo "ERROR: hosts.yaml not found or target node not identified"
        echo "Available nodes:"
        oc get nodes -l "${LABEL_SELECTOR}" --no-headers || true
        echo "Contents of SHARED_DIR:"
        ls -la "${SHARED_DIR}" || true
        exit 1
    fi
    
    export NODE_NAME="$target_node"

    # Run the node scenario
    echo "Starting node stop/start scenario for baremetal node..."
    ./node-disruptions/prow_run.sh
fi

rc=$?

if [[ $TELEMETRY_EVENTS_BACKUP == "True" ]]; then
    cp /tmp/events.json ${ARTIFACT_DIR}/events.json
fi

echo "Finished running node disruptions"
echo "Return code: $rc"
