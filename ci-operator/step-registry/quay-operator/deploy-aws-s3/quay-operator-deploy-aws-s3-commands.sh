#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
        "${_fURL[@]}" \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"; trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--quay-tests__deploy-quay-aws-s3__quay-tests-deploy-quay-aws-s3.xml
    ' EXIT
fi

QUAY_NS="quay-enterprise"

function archive_pod_info() {
  local ns="${QUAY_NS}"
  echo "Archiving pod status and logs from namespace ${ns}..."
  oc get pods -n "${ns}" -o wide > "${ARTIFACT_DIR}/pods_status.txt" 2>&1 || true
  oc get pods -n "${ns}" -o yaml > "${ARTIFACT_DIR}/pods_full.yaml" 2>&1 || true
  mkdir -p "${ARTIFACT_DIR}/pod_logs"
  while read -r pod; do
    containers=$(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)
    for container in ${containers}; do
      oc logs "${pod}" -n "${ns}" -c "${container}" > "${ARTIFACT_DIR}/pod_logs/${pod}_${container}.log" 2>&1 || true
      oc logs "${pod}" -n "${ns}" -c "${container}" --previous > "${ARTIFACT_DIR}/pod_logs/${pod}_${container}_previous.log" 2>&1 || true
    done
  done < <(oc get pods -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
}

#Get the credentials and Email of new Quay User
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)

# Create AWS S3 storage bucket. Names are globally unique; $RANDOM (0-32767)
# collides with leftover quay-tests buckets that use the same quayprowci prefix.
function new_s3_bucket_name() {
  local suffix
  suffix="${NAMESPACE:-ns}-${UNIQUE_HASH:-$(date +%s)}-${RANDOM}-$(date +%s)"
  suffix="$(printf '%s' "${suffix}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  printf 'quayprowci-%s\n' "${suffix}"
}

#Create AWS S3 Storage Bucket
QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"

QUAY_AWS_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/access_key)
QUAY_AWS_SECRET_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)

export AWS_ACCESS_KEY_ID="${QUAY_AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_AWS_SECRET_KEY}"

mkdir -p QUAY_AWS && cd QUAY_AWS
cat >>variables.tf <<EOF
variable "region" {
  default = "us-east-2"
}

variable "aws_bucket" {
  default = "quayaws"
}
EOF

cat >>create_aws_bucket.tf <<EOF
provider "aws" {
  region = "us-east-2"
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

terraform init
tf_apply_rc=1
for _ in 1 2 3 4 5; do
  QUAY_AWS_S3_BUCKET="$(new_s3_bucket_name)"
  echo "quay aws s3 bucket name is ${QUAY_AWS_S3_BUCKET}"
  export TF_VAR_aws_bucket="${QUAY_AWS_S3_BUCKET}"
  tf_apply_rc=0
  terraform apply -auto-approve || tf_apply_rc=$?
  if [[ "${tf_apply_rc}" -eq 0 ]]; then
    break
  fi
  echo "terraform apply failed with exit code ${tf_apply_rc}; retrying with a new bucket name" >&2
  terraform destroy -auto-approve || true
done

#Share Terraform Var and Terraform Directory for deprovision on success and failure
echo "${QUAY_AWS_S3_BUCKET}" > ${SHARED_DIR}/QUAY_AWS_S3_BUCKET
tar -cvzf terraform.tgz --exclude=".terraform" *
cp terraform.tgz ${SHARED_DIR}

if [[ "${tf_apply_rc}" -ne 0 ]]; then
  echo "terraform apply failed with exit code ${tf_apply_rc}" >&2
  exit "${tf_apply_rc}"
fi

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

CSV_READY=false
for _ in {1..60}; do
  CSV=$(oc -n quay-enterprise get subscription quay-operator -o jsonpath='{.status.installedCSV}' || true)
  if [[ -n "$CSV" ]]; then
    if [[ "$(oc -n quay-enterprise get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
      echo "ClusterServiceVersion \"$CSV\" ready"
      CSV_READY=true
      break
    fi
  fi
  sleep 10
done
if [[ "$CSV_READY" != "true" ]]; then
  echo "Timed out waiting for Quay Operator CSV to reach Succeeded phase" >&2
  echo "=== CSV Status ===" >&2
  oc -n quay-enterprise get csv -o wide 2>&1 || true
  echo "=== Subscription Status ===" >&2
  oc -n quay-enterprise get subscription quay-operator -o jsonpath='{.status}' 2>&1 || true
  echo "" >&2
  echo "=== CatalogSource Status ===" >&2
  oc get catalogsource -n openshift-marketplace -o wide 2>&1 || true
  archive_pod_info
  exit 1
fi
echo "Quay Operator is deployed successfully"

echo "Waiting for QuayRegistry CRD to be available..."
for _ in {1..30}; do
  if oc get crd quayregistries.quay.redhat.com &>/dev/null; then
    echo "QuayRegistry CRD is available"
    break
  fi
  sleep 5
done
if ! oc get crd quayregistries.quay.redhat.com &>/dev/null; then
  echo "Timed out waiting for QuayRegistry CRD" >&2
  echo "=== Operator Pod Logs ===" >&2
  oc logs -n quay-enterprise -l name=quay-operator --tail=100 2>&1 || true
  echo "=== Events ===" >&2
  oc get events -n quay-enterprise --sort-by='.lastTimestamp' 2>&1 | tail -30 || true
  archive_pod_info
  exit 1
fi

#Deploy Quay, here disable monitoring component
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
    - s3_bucket: $QUAY_AWS_S3_BUCKET
      storage_path: /quay
      s3_access_key: $QUAY_AWS_ACCESS_KEY
      s3_secret_key: $QUAY_AWS_SECRET_KEY
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

# Merge caller-provided extra config if set
if [[ -n "${QUAY_EXTRA_CONFIG:-}" ]]; then
	echo "Merging extra Quay config into defaults..."
	echo "${QUAY_EXTRA_CONFIG}" >extra_config.yaml
	curl -sL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
		-o /tmp/yq && chmod +x /tmp/yq
	/tmp/yq eval-all -i 'select(fileIndex == 0) *+ select(fileIndex == 1)' config.yaml extra_config.yaml
	# Strip field-group keys for components this CR keeps managed. The operator
	# injects those values; leaving them in configBundleSecret blocks rollout.
	/tmp/yq -i '
		del(
			.FEATURE_SECURITY_SCANNER,
			.FEATURE_SECURITY_NOTIFICATIONS,
			.SECURITY_SCANNER_ENDPOINT,
			.SECURITY_SCANNER_INDEXING_INTERVAL,
			.SECURITY_SCANNER_V4_ENDPOINT,
			.SECURITY_SCANNER_V4_NAMESPACE_WHITELIST,
			.SECURITY_SCANNER_V4_PSK,
			.FEATURE_REPO_MIRROR,
			.REPO_MIRROR_INTERVAL,
			.REPO_MIRROR_SERVER_HOSTNAME,
			.REPO_MIRROR_TLS_VERIFY,
			.BUILDLOGS_REDIS,
			.USER_EVENTS_REDIS,
			.DB_URI,
			.DB_CONNECTION_ARGS,
			.SERVER_HOSTNAME,
			.PREFERRED_URL_SCHEME,
			.EXTERNAL_TLS_TERMINATION
		)
	' config.yaml
fi

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

for _ in {1..60}; do
  if [[ "$(oc -n quay-enterprise get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' || true)" == "True" ]]; then
    echo "Quay is in ready status" >&2
    oc -n quay-enterprise get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
    oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}' > "$SHARED_DIR"/quayroute || true
    quay_route=$(oc get quayregistry quay -n quay-enterprise -o jsonpath='{.status.registryEndpoint}') || true
    curl -k -X POST $quay_route/api/v1/user/initialize --header 'Content-Type: application/json' \
         --data '{ "username": "'$QUAY_USERNAME'", "password": "'$QUAY_PASSWORD'", "email": "'$QUAY_EMAIL'", "access_token": true }' | jq '.access_token' | tr -d '"' | tr -d '\n' > "$SHARED_DIR"/quay_oauth2_token || true
    archive_pod_info
    exit 0
  fi
  sleep 15
done
echo "Timed out waiting for Quay to become ready after 15 mins" >&2
archive_pod_info
exit 1
