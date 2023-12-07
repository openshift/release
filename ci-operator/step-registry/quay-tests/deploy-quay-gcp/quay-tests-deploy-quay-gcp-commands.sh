#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


#Create AWS S3 Storage Bucket
QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"
QUAY_GCP_STORAGE_ID="quaygcpci$RANDOM"
GCP_ACCESS_KEY=$(cat /var/run/quay-qe-gcp-secret/access_key)
GCP_SECRET_KEY=$(cat /var/run/quay-qe-gcp-secret/secret_key)

#Copy GCP auth.json from mounted secret to current directory
cp /var/run/quay-qe-gcp-secret/auth.json . 

echo "quay new gcp storage bucket is $QUAY_GCP_STORAGE_ID"

cat >> variables.tf << EOF
variable "gcp_storage_bucket" {

}
EOF

cat >> create_gcp_storage_bucket.tf << EOF
provider "google" {
  credentials = file("auth.json")

  project = "openshift-qe"
  region  = "us-central1"
  zone    = "us-central1-c"
}

resource "google_storage_bucket" "quaygcp" {
  name          = var.gcp_storage_bucket
  location      = "US"
  force_destroy = true
}
EOF

export TF_VAR_gcp_storage_bucket="${QUAY_GCP_STORAGE_ID}"
terraform init
terraform apply -auto-approve

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
      - GoogleCloudStorage
      - access_key: $GCP_ACCESS_KEY
        bucket_name: $QUAY_GCP_STORAGE_ID
        secret_key: $GCP_SECRET_KEY
        storage_path: /quaygcp
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
