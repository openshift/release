#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


#Create Azure Storage Account and Storage Container
QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"

QUAY_AZURE_SUBSCRIPTION_ID=$(cat /var/run/quay-qe-azure-secret/subscription_id)
QUAY_AZURE_TENANT_ID=$(cat /var/run/quay-qe-azure-secret/tenant_id)
QUAY_AZURE_CLIENT_SECRET=$(cat /var/run/quay-qe-azure-secret/client_secret)
QUAY_AZURE_CLIENT_ID=$(cat /var/run/quay-qe-azure-secret/client_id)
QUAY_AZURE_STORAGE_ID="quayazure$RANDOM"

echo "quay azure storage ID is $QUAY_AZURE_STORAGE_ID"

cat >> variables.tf << EOF
variable "resource_group" {
    default = "quayazure"
}

variable "storage_account" {
    default = "quayazure"
}

variable "storage_container" {
    default = "quayazure"
}
EOF

cat >> create_azure_storage_container.tf << EOF
provider "azurerm" {
    subscription_id = "${QUAY_AZURE_SUBSCRIPTION_ID}"
    tenant_id       = "${QUAY_AZURE_TENANT_ID}"
    client_secret   = "${QUAY_AZURE_CLIENT_SECRET}"
    client_id       = "${QUAY_AZURE_CLIENT_ID}"

    features {}
}

resource "azurerm_resource_group" "quayazure" {
    name     = var.resource_group
    location = "westus"
}

resource "azurerm_storage_account" "quayazure" {
  name                     = var.storage_account
  resource_group_name      = azurerm_resource_group.quayazure.name
  location                 = azurerm_resource_group.quayazure.location
  account_tier             = "Standard"
  account_replication_type = "GRS"

}

resource "azurerm_storage_container" "quayazure" {
  name                  = var.storage_container
  storage_account_name  = azurerm_storage_account.quayazure.name
  container_access_type = "private"
}

data "azurerm_storage_account_sas" "quayazure" {
  connection_string = azurerm_storage_account.quayazure.primary_connection_string
  https_only        = true

  resource_types {
    service   = true
    container = true
    object    = true
  }

  services {
    blob  = true
    queue = true
    table = true
    file  = true
  }

  start  = "2022-07-24"
  expiry = "2024-07-25"

  permissions {
    read    = true
    write   = true
    delete  = true
    list    = true
    add     = true
    create  = true
    update  = true
    process = true
    tag     = false
    filter  = false
  }
}

output "sas_url_query_string" {
  value = data.azurerm_storage_account_sas.quayazure.sas
  sensitive = true
}

output "primary_access_key" {
  value = azurerm_storage_account.quayazure.primary_access_key
  sensitive = true
}
EOF

export TF_VAR_resource_group="${QUAY_AZURE_STORAGE_ID}"
export TF_VAR_storage_account="${QUAY_AZURE_STORAGE_ID}"
export TF_VAR_storage_container="${QUAY_AZURE_STORAGE_ID}"
terraform init
terraform apply -auto-approve

AZURE_ACCOUNT_KEY=$(terraform output primary_access_key)
SAS_TOKEN=$(terraform output sas_url_query_string)

#Deploy Quay Operator to OCP namespace 'quay-enterprise'
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: quay-enterprise
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quay
  namespace: quay-enterprise
spec:
  targetNamespaces:
  - quay-enterprise
EOF

SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: quay-enterprise
spec:
  installPlanApproval: Automatic
  name: quay-operator
  channel: $QUAY_OPERATOR_CHANNEL
  source: $QUAY_OPERATOR_SOURCE
  sourceNamespace: openshift-marketplace
EOF
)

echo "The Quay Operator subscription is $SUB"

for _ in {1..60}; do
    CSV=$(oc -n quay-enterprise get subscription quay-operator -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n quay-enterprise get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "ClusterServiceVersion \"$CSV\" ready"
            break
        fi
    fi
    sleep 10
done
echo "Quay Operator is deployed successfully"

#Deploy Quay, here disable monitoring component
cat >> config.yaml << EOF
CREATE_PRIVATE_REPO_ON_PUSH: true
CREATE_NAMESPACE_ON_PUSH: true
FEATURE_EXTENDED_REPOSITORY_NAMES: true
FEATURE_QUOTA_MANAGEMENT: true
FEATURE_PROXY_CACHE: true
FEATURE_USER_INITIALIZE: true
SUPER_USERS:
  - quay
USERFILES_LOCATION: default
USERFILES_PATH: userfiles/
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
  - default
DISTRIBUTED_STORAGE_PREFERENCE:
  - default
DISTRIBUTED_STORAGE_CONFIG:
    default:
      - AzureStorage
      - azure_account_key: $AZURE_ACCOUNT_KEY
        azure_account_name: $QUAY_AZURE_STORAGE_ID
        azure_container: $QUAY_AZURE_STORAGE_ID
        sas_token: $SAS_TOKEN
        storage_path: /quayazuredata/quayregistry
EOF

oc create secret generic -n quay-enterprise --from-file config.yaml=./config.yaml config-bundle-secret

echo "Creating Quay registry..." >&2
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: quay-enterprise
spec:
  configBundleSecret: config-bundle-secret
  components:
  - kind: objectstorage
    managed: false
  - kind: monitoring
    managed: false
EOF

for _ in {1..60}; do
    if [[ "$(oc -n quay-enterprise get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
        echo "Quay is in ready status" >&2
        exit 0
    fi
    sleep 15
done
echo "Timed out waiting for Quay to become ready afer 15 mins" >&2
oc -n quay-enterprise get quayregistries -o yaml > "$ARTIFACT_DIR/quayregistries.yaml"
