#!/bin/bash

if [ "$ENABLEPEERPODS" != "true" ]; then
    echo "skip as ENABLEPEERPODS is not true"
    exit 0
fi

# Switch to a directory with rw permission
cd /tmp || exit 1

# Create the parameters configmap file in the shared directory so that others steps
# can reference it.
PP_CONFIGM_PATH="${SHARED_DIR:-$(pwd)}/peerpods-param-cm.yaml"

handle_aws() {
    local AWS_REGION
    local AWS_SG_IDS
    local AWS_SUBNET_ID
    local AWS_VPC_ID
    local INSTANCE_ID

    oc -n kube-system get secret aws-creds -o json > aws-creds.json

    AWS_ACCESS_KEY_ID="$(jq -r .data.aws_access_key_id aws-creds.json | base64 -d)"
    export AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY="$(jq -r .data.aws_secret_access_key aws-creds.json | base64 -d)"
    export AWS_SECRET_ACCESS_KEY

    cat<<-EOF > ./auth.json
    {
      "aws": {
        "aws_access_key_id": "${AWS_ACCESS_KEY_ID}",
        "aws_secret_access_key": "${AWS_SECRET_ACCESS_KEY}"
      }
    }
EOF

    oc create secret generic peerpods-param-secret --from-file=./auth.json -n default

    INSTANCE_ID=$(oc get nodes -l 'node-role.kubernetes.io/worker' -o jsonpath='{.items[0].spec.providerID}' | sed 's#[^ ]*/##g')
    AWS_REGION=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.aws.region}')
    AWS_SUBNET_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[*].Instances[*].SubnetId' --region "${AWS_REGION}" --output text)
    AWS_VPC_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[*].Instances[*].VpcId' --region "${AWS_REGION}" --output text)
    AWS_SG_IDS=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[*].Instances[*].SecurityGroups[*].GroupId' --region "${AWS_REGION}" --output text | tr ' \t' ',')

    # Opening ports
    for AWS_SG_ID in ${AWS_SG_IDS/,/ }; do
        aws ec2 authorize-security-group-ingress \
            --group-id "${AWS_SG_ID}" --protocol tcp --port 15150 \
            --source-group "${AWS_SG_ID}" --region "${AWS_REGION}" \
            --no-paginate
        aws ec2 authorize-security-group-ingress \
            --group-id "${AWS_SG_ID}" --protocol tcp --port 9000 \
            --source-group "${AWS_SG_ID}" --region "${AWS_REGION}" \
            --no-paginate
    done

    cat <<-EOF > "${PP_CONFIGM_PATH}"
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: peerpods-param-cm
      namespace: default
    data:
      CLOUD_PROVIDER: "aws"
      AWS_REGION: "${AWS_REGION}"
      AWS_SUBNET_ID: "${AWS_SUBNET_ID}"
      AWS_VPC_ID: "${AWS_VPC_ID}"
      AWS_SG_IDS: "${AWS_SG_IDS}"
      VXLAN_PORT: "9000"
      PODVM_INSTANCE_TYPE: "t3.medium"
      PODVM_INSTANCE_TYPES: "t3.small,t3.medium,t3.large,t3.xlarge,g4dn.2xlarge,g5.2xlarge,p3.2xlarge"
      PROXY_TIMEOUT: "30m"
EOF
}

# Create a SSH keys pair. The public key is exported and later set in
# the peerpods-param-cm.
#
create_ssh_key() {

    # The following was copied from the ipi-config-sshkey step
    #
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

    local key_file="/tmp/id_ed25519"
    ssh-keygen -t ed25519 -f "${key_file}" -N ""
    PP_SSH_KEY_PUB=$(base64 -w 0 < "${key_file}.pub")
    export PP_SSH_KEY_PUB
}

# Create OSC operator managed identity and federated credential for STS mode
# This function is called only when IDENTITY_MODE=sts
create_osc_managed_identity() {
    local OSC_IDENTITY_NAME="osc-${AZURE_RESOURCE_GROUP}"
    local OSC_IDENTITY_PRINCIPAL_ID
    local OSC_CLIENT_ID
    local SUBSCRIPTION_SCOPE="/subscriptions/${AZURE_SUBSCRIPTION_ID}"
    local ISSUER_URL
    local retry_count=0

    echo "Creating managed identity for OSC operator: ${OSC_IDENTITY_NAME}"

    # Create managed identity
    az identity create \
        --name "${OSC_IDENTITY_NAME}" \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --location "${AZURE_REGION}"

    # Wait for identity to propagate in Azure (can take up to 15 seconds)
    echo "Waiting for managed identity to propagate in Azure..."
    while [ $retry_count -lt 6 ]; do
        OSC_IDENTITY_PRINCIPAL_ID=$(az identity show \
            --name "${OSC_IDENTITY_NAME}" \
            --resource-group "${AZURE_RESOURCE_GROUP}" \
            --query principalId -o tsv 2>/dev/null || echo "")

        if [[ -n "${OSC_IDENTITY_PRINCIPAL_ID}" ]]; then
            echo "Identity propagated successfully"
            break
        fi

        echo "Identity not ready yet, waiting 5 seconds... (attempt $((retry_count+1))/6)"
        sleep 5
        ((retry_count++))
    done

    if [[ -z "${OSC_IDENTITY_PRINCIPAL_ID}" ]]; then
        echo "ERROR: Failed to get principal ID after 30 seconds - identity not propagated"
        exit 1
    fi

    echo "Managed identity principal ID: ${OSC_IDENTITY_PRINCIPAL_ID}"

    # Get clientId (should be available now that principalId is)
    OSC_CLIENT_ID=$(az identity show \
        --name "${OSC_IDENTITY_NAME}" \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --query clientId -o tsv)

    if [[ -z "${OSC_CLIENT_ID}" ]]; then
        echo "ERROR: Failed to get clientId from managed identity"
        exit 1
    fi

    echo "OSC operator managed identity clientId: ${OSC_CLIENT_ID}"

    # Assign required roles (matching Jenkins implementation)
    echo "Assigning roles to managed identity..."
    for ROLE in "Reader" "Virtual Machine Contributor" "Network Contributor" "Storage Account Contributor" "Compute Gallery Artifacts Publisher"; do
        echo "Assigning role: ${ROLE}"
        az role assignment create \
            --role "${ROLE}" \
            --assignee "${OSC_IDENTITY_PRINCIPAL_ID}" \
            --scope "${SUBSCRIPTION_SCOPE}"
    done

    # Get OIDC issuer URL from cluster
    ISSUER_URL=$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}')
    if [[ -z "${ISSUER_URL}" ]]; then
        echo "ERROR: Failed to get OIDC issuer URL from cluster"
        exit 1
    fi
    echo "OIDC Issuer URL: ${ISSUER_URL}"

    # Create federated identity credential
    echo "Creating federated identity credential..."
    az identity federated-credential create \
        --name "${OSC_IDENTITY_NAME}-federation" \
        --identity-name "${OSC_IDENTITY_NAME}" \
        --resource-group "${AZURE_RESOURCE_GROUP}" \
        --issuer "${ISSUER_URL}" \
        --subject "system:serviceaccount:openshift-sandboxed-containers-operator:default" \
        --audiences "openshift"

    # Create osc-identity ConfigMap
    echo "Creating osc-identity ConfigMap..."
    oc create configmap osc-identity \
        --from-literal=subscriptionId="${AZURE_SUBSCRIPTION_ID}" \
        --from-literal=clientId="${OSC_CLIENT_ID}" \
        --from-literal=tenantId="${AZURE_TENANT_ID}" \
        -n default

    echo "STS identity setup complete for OSC operator"
}

handle_azure() {
    local IS_ARO
    local AZURE_RESOURCE_GROUP
    local AZURE_AUTH_LOCATION
    local AZURE_CLIENT_SECRET
    local AZURE_TENANT_ID
    local AZURE_CLIENT_ID
    local AZURE_VNET_NAME
    local AZURE_SUBNET_ID
    local AZURE_SUBNET_NAME
    local AZURE_NSG_ID
    local AZURE_REGION
    local MANAGEMENT_RESOURCE_GROUP
    local PP_REGION
    local PP_RESOURCE_GROUP
    local PP_VNET_NAME
    local PP_SUBNET_NAME
    local PP_SUBNET_ID
    local PP_RESOURCE_GROUP
    local PP_NSG_ID

    IS_ARO=$(oc get crd clusters.aro.openshift.io &>/dev/null && echo true || echo false)
    # Note: Keep the following commands in sync with https://raw.githubusercontent.com/kata-containers/kata-containers/refs/heads/main/ci/openshift-ci/peer-pods-azure.sh
    # as much as possible.

    ###############################
    # Disable security to allow e2e
    ###############################
    # Disable security
    oc adm policy add-scc-to-group privileged system:authenticated system:serviceaccounts
    oc adm policy add-scc-to-group anyuid system:authenticated system:serviceaccounts
    oc label --overwrite ns default pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/warn=baseline pod-security.kubernetes.io/audit=baseline

    oc -n kube-system get secret azure-credentials -o json > azure_credentials.json
    if [ -n "${CLUSTER_PROFILE_DIR:-}" ]; then
        AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
        AZURE_CLIENT_ID="$(jq -r .clientId "${AZURE_AUTH_LOCATION}")"
        AZURE_CLIENT_SECRET="$(jq -r .clientSecret "${AZURE_AUTH_LOCATION}")"
        AZURE_TENANT_ID="$(jq -r .tenantId "${AZURE_AUTH_LOCATION}")"
    else
        # Useful when testing this script outside of ci-operator
        AZURE_CLIENT_ID="$(jq -r .data.azure_client_id azure_credentials.json|base64 -d)"
        AZURE_CLIENT_SECRET="$(jq -r .data.azure_client_secret azure_credentials.json|base64 -d)"
        AZURE_TENANT_ID="$(jq -r .data.azure_tenant_id azure_credentials.json|base64 -d)"
    fi
    AZURE_SUBSCRIPTION_ID="$(jq -r .data.azure_subscription_id azure_credentials.json|base64 -d)"
    rm -f azure_credentials.json
    # Login to Azure for NAT gateway creation
    az login --service-principal --username "${AZURE_CLIENT_ID}" --password "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}"
    az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

    # Get resource group based on identity mode
    if [[ "${IDENTITY_MODE:-cco}" == "sts" ]]; then
        # STS mode - resource group created by ccoctl
        if [[ -s "${SHARED_DIR}/resourcegroup_cluster" ]]; then
            AZURE_RESOURCE_GROUP=$(cat "${SHARED_DIR}/resourcegroup_cluster")
            echo "STS mode - using resource group from ccoctl: ${AZURE_RESOURCE_GROUP}"
        else
            echo "ERROR: STS mode enabled but resourcegroup_cluster not found in ${SHARED_DIR}"
            echo "This file should be created by ipi-conf-azure-oidc-creds-provision step"
            exit 1
        fi
    else
        # CCO/Manual mode - get from cluster infrastructure
        AZURE_RESOURCE_GROUP=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
        echo "CCO/Manual mode - using resource group from cluster: ${AZURE_RESOURCE_GROUP}"
    fi

    AZURE_REGION=$(az group show --resource-group "${AZURE_RESOURCE_GROUP}" --query "{Location:location}" --output tsv)

    if [[ "${IS_ARO}" == "true" ]]; then
        # Use ARO credentials but remember MANAGEMENT_RESOURCE_GROUP for vnet configuration
        MANAGEMENT_RESOURCE_GROUP="$(cat "${SHARED_DIR}/resourcegroup")"
        oc -n kube-system get secret azure-credentials -o json > azure_credentials.json
        AZURE_CLIENT_ID="$(jq -r .data.azure_client_id azure_credentials.json|base64 -d)"
        AZURE_CLIENT_SECRET="$(jq -r .data.azure_client_secret azure_credentials.json|base64 -d)"
        AZURE_TENANT_ID="$(jq -r .data.azure_tenant_id azure_credentials.json|base64 -d)"
        rm -f azure_credentials.json
    else
        MANAGEMENT_RESOURCE_GROUP="$AZURE_RESOURCE_GROUP"
    fi
    for I in {1..30}; do
	    AZURE_VNET_NAME=$(az network vnet list --resource-group "${MANAGEMENT_RESOURCE_GROUP}" --query "[].{Name:name}" --output tsv ||:)
	    if [[ -z "${AZURE_VNET_NAME}" ]]; then
		    sleep "${I}"
	    else	# VNET set, we are done
		    break
	    fi
    done
    if [[ -z "${AZURE_VNET_NAME}" ]]; then
	    echo "Failed to get AZURE_VNET_NAME in 30 iterations"
	    exit 1
    fi

    AZURE_SUBNET_NAME=$(az network vnet subnet list --resource-group "${MANAGEMENT_RESOURCE_GROUP}" --vnet-name "${AZURE_VNET_NAME}" --query "[].{Id:name} | [? contains(Id, 'worker')]" --output tsv)
    AZURE_SUBNET_ID=$(az network vnet subnet list --resource-group "${MANAGEMENT_RESOURCE_GROUP}" --vnet-name "${AZURE_VNET_NAME}" --query "[].{Id:id} | [? contains(Id, 'worker')]" --output tsv)
    AZURE_NSG_ID=$(az network nsg list --resource-group "${AZURE_RESOURCE_GROUP}" --query "[].{Id:id}" --output tsv)

    # Downstream version generates podvm, no need to peer to eastus
    # (keeping the PP_* variables to be close to upstream setup)
    PP_REGION="${AZURE_REGION}"
    PP_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}"
    PP_VNET_NAME="${AZURE_VNET_NAME}"
    PP_SUBNET_NAME="${AZURE_SUBNET_NAME}"
    PP_SUBNET_ID="${AZURE_SUBNET_ID}"
    PP_NSG_ID="${AZURE_NSG_ID}"

    # Peer-pod requires gateway
    az network public-ip create \
        --resource-group "${MANAGEMENT_RESOURCE_GROUP}" \
        --name MyPublicIP \
        --sku Standard \
        --allocation-method Static
    az network nat gateway create \
        --resource-group "${MANAGEMENT_RESOURCE_GROUP}" \
        --name MyNatGateway \
        --public-ip-addresses MyPublicIP \
        --idle-timeout 10
    az network vnet subnet update \
        --resource-group "${MANAGEMENT_RESOURCE_GROUP}" \
        --vnet-name "${PP_VNET_NAME}" \
        --name "${PP_SUBNET_NAME}" \
        --nat-gateway MyNatGateway

    create_ssh_key

    # Creating peerpods-param-cm config map with all the cloud params needed for test case execution
    cat <<- EOF > "${PP_CONFIGM_PATH}"
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: peerpods-param-cm
      namespace: default
    data:
      CLOUD_PROVIDER: "azure"
      VXLAN_PORT: "9000"
      AZURE_INSTANCE_SIZE: "Standard_B2als_v2"
      AZURE_INSTANCE_SIZES: Standard_B2als_v2,Standard_B2as_v2,Standard_D2as_v5,Standard_B4als_v2,Standard_D4as_v5,Standard_D8as_v5,Standard_NC64as_T4_v3,Standard_NC8as_T4_v3
      AZURE_SSH_KEY_PUB: "${PP_SSH_KEY_PUB}"
      AZURE_SUBNET_ID: "${PP_SUBNET_ID}"
      AZURE_NSG_ID: "${PP_NSG_ID}"
      AZURE_RESOURCE_GROUP: "${PP_RESOURCE_GROUP}"
      AZURE_REGION: "${PP_REGION}"
      PROXY_TIMEOUT: "30m"
EOF

    # Handle identity mode - create managed identity for STS or secret for manual mode
    case "${IDENTITY_MODE:-cco}" in
        sts)
            echo "STS mode - creating OSC operator managed identity and osc-identity ConfigMap"
            create_osc_managed_identity
            ;;
        manual)
            echo "Manual mode - creating peerpods-param-secret"
            if [[ -z "${AZURE_AUTH_LOCATION}" ]]; then
                AZURE_AUTH_LOCATION="${PWD}/osServicePrincipal.json"
                echo "{ \"clientId\": \"$AZURE_CLIENT_ID\", \"clientSecret\": \"$AZURE_CLIENT_SECRET\", \"tenantId\": \"$AZURE_TENANT_ID\" }" | \
                    jq > "${AZURE_AUTH_LOCATION}"
            fi
            oc create secret generic peerpods-param-secret --from-file="${AZURE_AUTH_LOCATION}" -n default
            ;;
        cco)
            echo "CCO mode - no secret or managed identity needed (CCO manages credentials)"
            ;;
        *)
            echo "ERROR: Invalid IDENTITY_MODE='${IDENTITY_MODE}'. Supported values: cco, manual, sts"
            exit 1
            ;;
    esac
}

provider="$(oc get infrastructure -n cluster -o json | jq '.items[].status.platformStatus.type'  | awk '{print tolower($0)}' | tr -d '"')"
echo "Creating peerpods-param-cm for ${provider}"
case $provider in
    aws)
        handle_aws ;;
    azure)
        handle_azure ;;
    *)
        echo "ERROR: handler not implemented for that provider"
        exit 1 ;;
esac

oc create -f "${PP_CONFIGM_PATH}"
