#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        curl -fsSL \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"; trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--quay-tests__deploy-quay-aws-s3__quay-tests-deploy-quay-aws-s3.xml
    ' EXIT
fi

ArchivePodInfo() {
    typeset ns="quay-enterprise"
    typeset pod="" container=""
    oc get pods -n "${ns}" -o wide > "${ARTIFACT_DIR}/pods_status.txt" 2>&1 || true
    oc get pods -n "${ns}" -o yaml > "${ARTIFACT_DIR}/pods_full.yaml" 2>&1 || true
    mkdir -p "${ARTIFACT_DIR}/pod_logs"
    while read -r pod; do
        containers="$(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.containers[*].name}' || true)"
        for container in ${containers}; do
            oc logs "${pod}" -n "${ns}" -c "${container}" > "${ARTIFACT_DIR}/pod_logs/${pod}_${container}.log" 2>&1 || true
            oc logs "${pod}" -n "${ns}" -c "${container}" --previous > "${ARTIFACT_DIR}/pod_logs/${pod}_${container}_previous.log" 2>&1 || true
        done
    done < <(oc get pods -n "${ns}" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')
    true
}

#Get the credentials and Email of new Quay User
set +x
typeset quayUsername quayPassword quayEmail quayAwsAccessKey quayAwsSecretKey
quayUsername="$(cat /var/run/quay-qe-quay-secret/username)"
quayPassword="$(cat /var/run/quay-qe-quay-secret/password)"
quayEmail="$(cat /var/run/quay-qe-quay-secret/email)"
quayAwsAccessKey="$(cat /var/run/quay-qe-aws-secret/access_key)"
quayAwsSecretKey="$(cat /var/run/quay-qe-aws-secret/secret_key)"
set -x

#Create AWS S3 Storage Bucket
typeset quayAwsS3Bucket="quayprowci${RANDOM}"

mkdir -p QUAY_AWS && cd QUAY_AWS
cat >>variables.tf <<EOF
variable "region" {
  default = "us-east-2"
}

variable "aws_bucket" {
  default = "quayaws"
}
EOF

set +x
cat >>create_aws_bucket.tf <<EOF
provider "aws" {
  region = "us-east-2"
  access_key = "${quayAwsAccessKey}"
  secret_key = "${quayAwsSecretKey}"
}

resource "aws_s3_bucket" "quayaws" {
  bucket = var.aws_bucket
  force_destroy = true
}

resource "aws_s3_bucket_ownership_controls" "quayaws" {
  bucket = aws_s3_bucket.quayaws.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "quayaws_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.quayaws]

  bucket = aws_s3_bucket.quayaws.id
  acl    = "private"
}
EOF
set -x

export TF_VAR_aws_bucket="${quayAwsS3Bucket}"
terraform init
terraform apply -auto-approve || true

#Share Terraform Var and Terraform Directory
echo "${quayAwsS3Bucket}" > "${SHARED_DIR}/QUAY_AWS_S3_BUCKET"
tar -cvzf terraform.tgz --exclude=".terraform" *
cp terraform.tgz "${SHARED_DIR}/"

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

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: quay-enterprise
spec:
  installPlanApproval: Automatic
  name: quay-operator
  channel: ${QUAY_OPERATOR_CHANNEL}
  source: ${QUAY_OPERATOR_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

typeset -i waitIdx=0
typeset csv=""
for ((waitIdx = 1; waitIdx <= 60; waitIdx++)); do
  csv="$(oc -n quay-enterprise get subscription quay-operator -o jsonpath='{.status.installedCSV}' || true)"
  if [[ -n "${csv}" ]]; then
    if [[ "$(oc -n quay-enterprise get csv "${csv}" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
      break
    fi
  fi
  sleep 10
done

for ((waitIdx = 1; waitIdx <= 30; waitIdx++)); do
  if oc get crd quayregistries.quay.redhat.com >/dev/null; then
    break
  fi
  sleep 5
done
if ! oc get crd quayregistries.quay.redhat.com >/dev/null; then
  echo "Timed out waiting for QuayRegistry CRD" 1>&2
  exit 1
fi

set +x
cat >>config.yaml <<EOF
CREATE_PRIVATE_REPO_ON_PUSH: true
CREATE_NAMESPACE_ON_PUSH: true
FEATURE_EXTENDED_REPOSITORY_NAMES: true
FEATURE_QUOTA_MANAGEMENT: true
FEATURE_AUTO_PRUNE: true
FEATURE_PROXY_CACHE: true
FEATURE_USER_INITIALIZE: true
PERMANENTLY_DELETE_TAGS: true
RESET_CHILD_MANIFEST_EXPIRATION: true
FEATURE_PROXY_STORAGE: true
FEATURE_SUPERUSER_CONFIGDUMP: true
FEATURE_UI_V2: true
FEATURE_SUPERUSERS_FULL_ACCESS: true
FEATURE_UI_MODELCARD: true
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
    - S3Storage
    - s3_bucket: ${quayAwsS3Bucket}
      storage_path: /quay
      s3_access_key: ${quayAwsAccessKey}
      s3_secret_key: ${quayAwsSecretKey}
      host: s3.us-east-2.amazonaws.com
      s3_region: us-east-2
FEATURE_ANONYMOUS_ACCESS: true
BROWSER_API_CALLS_XHR_ONLY: false
FEATURE_USERNAME_CONFIRMATION: false
AUTHENTICATION_TYPE: Database
FEATURE_LISTEN_IP_VERSION: IPv4
REPO_MIRROR_ROLLBACK: false
AUTOPRUNE_TASK_RUN_MINIMUM_INTERVAL_MINUTES: 1
FEATURE_IMAGE_EXPIRY_TRIGGER: true 
NOTIFICATION_TASK_RUN_MINIMUM_INTERVAL_MINUTES: 1 
DEFAULT_TAG_EXPIRATION: 2w
TAG_EXPIRATION_OPTIONS:
  - 2w
  - 4w
  - 8w
  - 1d
REDIS_FLUSH_INTERVAL_SECONDS: 30
FEATURE_IMAGE_PULL_STATS: true
FEATURE_ORG_MIRROR: true
FEATURE_IMMUTABLE_TAGS: true
PULL_METRICS_REDIS:
        host: quay-quay-redis
        port: 6379
        db: 1
EOF
set -x

if [[ -n "${QUAY_EXTRA_CONFIG}" ]]; then
    echo "${QUAY_EXTRA_CONFIG}" >extra_config.yaml
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
        -o /tmp/yq && chmod +x /tmp/yq
    /tmp/yq eval-all -i 'select(fileIndex == 0) *+ select(fileIndex == 1)' config.yaml extra_config.yaml
fi

oc create secret generic -n quay-enterprise --from-file config.yaml=./config.yaml config-bundle-secret --dry-run=client -o yaml | oc apply -f -
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
  - kind: horizontalpodautoscaler
    managed: true
  - kind: quay
    managed: true
  - kind: mirror
    managed: true
  - kind: clair
    managed: true
  - kind: tls
    managed: true
  - kind: route
    managed: true
EOF

typeset quayRoute=""
for ((waitIdx = 1; waitIdx <= 60; waitIdx++)); do
  if [[ "$(oc -n quay-enterprise get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
    oc -n quay-enterprise get quayregistries -o yaml >"${ARTIFACT_DIR}/quayregistries.yaml"
    quayRoute="$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}')"
    echo "${quayRoute}" > "${SHARED_DIR}/quayroute"
    set +x
    jq -cn \
        --arg username "${quayUsername}" \
        --arg password "${quayPassword}" \
        --arg email "${quayEmail}" \
        '{username: $username, password: $password, email: $email, access_token: true}' |
    curl -fsSk -X POST "${quayRoute}/api/v1/user/initialize" \
        --header 'Content-Type: application/json' \
        --data @- |
    jq -r '.access_token' | tr -d '\n' > "${SHARED_DIR}/quay_oauth2_token"
    set -x
    ArchivePodInfo
    exit 0
  fi
  sleep 15
done
ArchivePodInfo
echo "Timed out waiting for Quay to become ready after 15 mins" 1>&2
exit 1
