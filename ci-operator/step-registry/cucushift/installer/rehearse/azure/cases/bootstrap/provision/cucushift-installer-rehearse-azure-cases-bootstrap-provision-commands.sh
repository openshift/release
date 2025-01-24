#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'save_artifacts; if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(<"${AZURE_AUTH_LOCATION}" jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(<"${AZURE_AUTH_LOCATION}" jq -r .tenantId)"

# log in with az
if [[ "${CLUSTER_TYPE}" == "azuremag" ]]; then
    az cloud set --name AzureUSGovernment
elif [[ "${CLUSTER_TYPE}" == "azurestack" ]]; then
    if [ ! -f "${CLUSTER_PROFILE_DIR}/cloud_name" ]; then
        echo "Unable to get specific ASH cloud name!"
        exit 1
    fi
    cloud_name=$(< "${CLUSTER_PROFILE_DIR}/cloud_name")

    AZURESTACK_ENDPOINT=$(cat "${SHARED_DIR}"/AZURESTACK_ENDPOINT)
    SUFFIX_ENDPOINT=$(cat "${SHARED_DIR}"/SUFFIX_ENDPOINT)

    if [[ -f "${CLUSTER_PROFILE_DIR}/ca.pem" ]]; then
        cp "${CLUSTER_PROFILE_DIR}/ca.pem" /tmp/ca.pem
        cat /usr/lib64/az/lib/python*/site-packages/certifi/cacert.pem >> /tmp/ca.pem
        export REQUESTS_CA_BUNDLE=/tmp/ca.pem
    fi
    az cloud register \
        -n ${cloud_name} \
        --endpoint-resource-manager "${AZURESTACK_ENDPOINT}" \
        --suffix-storage-endpoint "${SUFFIX_ENDPOINT}"
    az cloud set --name ${cloud_name}
    az cloud update --profile 2019-03-01-hybrid
else
    az cloud set --name AzureCloud
fi
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}" --output none

function save_artifacts()
{
    set +o errexit
    cp "${install_dir}/metadata.json" "${SHARED_DIR}/metadata.json"
    cp "${install_dir}"/log-bundle-*.tar.gz "${ARTIFACT_DIR}/" 2>/dev/null

    current_time=$(date +%s)
    sed '
      s/password: .*/password: REDACTED/;
      s/X-Auth-Token.*/X-Auth-Token REDACTED/;
      s/UserData:.*,/UserData: REDACTED,/;
      ' "${install_dir}/.openshift_install.log" > "${ARTIFACT_DIR}/openshift_install-${current_time}.log"

    if [ -d "${install_dir}/.clusterapi_output" ]; then
        mkdir -p "${ARTIFACT_DIR}/clusterapi_output-${current_time}"
        cp -rpv "${install_dir}/.clusterapi_output/"{,**/}*.{log,yaml} "${ARTIFACT_DIR}/clusterapi_output-${current_time}" 2>/dev/null
    fi

    set -o errexit
}

function ssh_command() {
    local node_ip="$1"
    local cmd="$2"
    local ssh_options ssh_proxy_command="" bastion_ip bastion_ssh_user

    ssh_options="-o UserKnownHostsFile=/dev/null -o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no"
    if [[ -f "${SHARED_DIR}/bastion_public_address" ]]; then
        bastion_ip=$(<"${SHARED_DIR}/bastion_public_address")
        bastion_ssh_user=$(<"${SHARED_DIR}/bastion_ssh_user")
        ssh_proxy_command="-o ProxyCommand='ssh ${ssh_options} -W %h:%p ${bastion_ssh_user}@${bastion_ip}'"
    fi

    echo "ssh ${ssh_options} ${ssh_proxy_command} core@${node_ip} '${cmd}'" | sh -
}

if [[ -z "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" ]]; then
  echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE is an empty string, exiting"
  exit 1
fi
echo "Installing from release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

check_result=0

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
cluster_name="${NAMESPACE}-${UNIQUE_HASH}"
install_dir="/tmp/${cluster_name}"
mkdir -p ${install_dir}
cat "${SHARED_DIR}/install-config.yaml" > "${install_dir}/install-config.yaml"

echo "Creating cluster ..."
cat "${install_dir}/install-config.yaml" | grep -v "password\|username\|pullSecret\|auth" | tee ${ARTIFACT_DIR}/install-config.yaml
export AZURE_AUTH_LOCATION=${CLUSTER_PROFILE_DIR}/osServicePrincipal.json
openshift-install create cluster --dir="${install_dir}" 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &

try=0
max_try=25
while [[ ${try} -lt ${max_try} ]]; do
    if grep -qP 'Waiting up to 45m0s.*for bootstrapping to complete...' "${install_dir}/.openshift_install.log"; then
        echo "INFO: installer ran into stage of waiting for bootstrap to complete, break the installation..."
        # shellcheck disable=SC2046
        kill $(jobs -p)
        break
    fi
    echo "waiting for installer running into stage of waiting for bootstrap to complete..."
    sleep 120
    try=$(( try + 1 ))
done

if [ X"${try}" == X"${max_try}" ]; then
    echo "ERROR: installer does not run into bootstrap complete stage, exit!"
    exit 1
fi

# Check that all clients on bootstrap host to localhost for k8s API access
echo "**********Check that all clients on bootstrap host to localhost for k8s API access*********"
infra_id=$(jq -r '.infraID' ${install_dir}/metadata.json)
resource_group="${infra_id}-rg"
bootstrap_public_ip_id=$(az network lb frontend-ip list --lb-name ${infra_id} -g ${resource_group} -ojson | jq -r '.[] | select(.inboundNatRules != null) | .publicIPAddress.id')
bootstrap_public_ip=$(az network public-ip show --ids ${bootstrap_public_ip_id} --query 'ipAddress' -otsv)
server=$(ssh_command "${bootstrap_public_ip}" "sudo KUBECONFIG=/etc/kubernetes/kubeconfig oc config view --minify -o=jsonpath='{.clusters[].cluster.server}'")
if [[ ${server} =~ "localhost:6443" ]]; then
    echo "INFO: Server set to localhost - PASS"
else
    echo "ERROR: Server NOT set to localhost! result from bootstrap host: ${server}"
    check_result=1
fi

# Destroy bootsrap host and related resources
echo "Destroy bootstrap host by running command: openshift-install destroy bootstrap"
openshift-install destroy bootstrap --dir ${install_dir} || check_result=1

exit ${check_result}
