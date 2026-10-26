#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

command -v yq >/dev/null || { echo "yq not found in image ci/quay-deploy-tools; refusing to download at runtime" >&2; exit 1; }

if [ "${MAP_TESTS}" = "true" ]; then
    exit_trap_ref="6263d6941034bf16cfc10b2bca7433ccf22fde60"
    exit_trap_sha256="bfc394cc4586576e2c0473d8a276ecb2fa456792fdd9114c23c1be54d9982305"
    exit_trap_script="$(mktemp)"
    exit_trap_url="https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/${exit_trap_ref}/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh"
    curl -fsSL -o "${exit_trap_script}" "${exit_trap_url}"
    printf '%s  %s\n' "${exit_trap_sha256}" "${exit_trap_script}" | sha256sum --check --status
    eval "$(cat "${exit_trap_script}")"
    rm -f "${exit_trap_script}"
fi

QL_INSTALL_START=""
QL_INSTALL_STATUS=""
QL_INSTALL_FAILURE=""

# shellcheck disable=SC2329
function ql_xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}

# shellcheck disable=SC2329
function write_quay_install_junit() {
  local exit_code="$1"

  if [[ -z "${QL_INSTALL_START}" ]]; then
    return 0
  fi

  if [[ -z "${QL_INSTALL_STATUS}" && "${exit_code}" -ne 0 ]]; then
    QL_INSTALL_STATUS="failed"
    QL_INSTALL_FAILURE="step exited with status ${exit_code}"
  fi

  local install_time=$(( $(date +%s) - QL_INSTALL_START ))
  local failures=0
  [[ "${QL_INSTALL_STATUS}" == "failed" ]] && failures=1

  local tmp
  tmp="$(mktemp "${ARTIFACT_DIR}/junit_quay_install.xml.XXXXXX")"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    printf '<testsuite name="quay-lifecycle" tests="1" failures="%d" skipped="0" time="%d">\n' \
      "${failures}" "${install_time}"
    printf '  <testcase name="[sig-quay] install should succeed" time="%d"' "${install_time}"
    if [[ "${failures}" -eq 1 ]]; then
      printf '>\n    <failure message="%s">%s</failure>\n  </testcase>\n' \
        "$(ql_xml_escape "${QL_INSTALL_FAILURE}")" "$(ql_xml_escape "${QL_INSTALL_FAILURE}")"
    else
      printf '/>\n'
    fi
    echo '</testsuite>'
  } > "${tmp}"
  mv "${tmp}" "${ARTIFACT_DIR}/junit_quay_install.xml"
}

# shellcheck disable=SC2329
function on_exit() {
  local ec=$?
  if [ "${MAP_TESTS}" = "true" ]; then
    LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
      ExitTrap--PostProcessPrep junit--quay-tests__deploy-quay-ibmcloud-cos__quay-tests-deploy-quay-ibmcloud-cos.xml || true
  fi
  write_quay_install_junit "${ec}"
  exit "${ec}"
}
trap on_exit EXIT

QUAY_NS="quay-enterprise"

function archive_pod_info() {
  local ns="${QUAY_NS}"
  echo "Archiving pod status and logs from namespace ${ns}..."
  oc get pods -n "${ns}" -o wide > "${ARTIFACT_DIR}/pods_status.txt" 2>&1 || true
  oc get pods -n "${ns}" -o yaml > "${ARTIFACT_DIR}/pods_full.yaml" 2>&1 || true
  mkdir -p "${ARTIFACT_DIR}/pod_logs"
  while read -r pod; do
    [[ -z "${pod}" ]] && continue
    containers=$(oc get pod "${pod}" -n "${ns}" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null || true)
    for container in ${containers}; do
      oc logs "${pod}" -n "${ns}" -c "${container}" > "${ARTIFACT_DIR}/pod_logs/${pod}_${container}.log" 2>&1 || true
      oc logs "${pod}" -n "${ns}" -c "${container}" --previous > "${ARTIFACT_DIR}/pod_logs/${pod}_${container}_previous.log" 2>&1 || true
    done
  done < <(oc get pods -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')
}

function print_quayregistry_conditions() {
  local ns="${QUAY_NS}"
  if command -v jq >/dev/null 2>&1; then
    oc -n "${ns}" get quayregistry quay -o json 2>/dev/null \
      | jq -r '.status.conditions[]? | "\(.type)=\(.status) reason=\(.reason // "") msg=\(.message // "")"' >&2 || true
  else
    oc -n "${ns}" get quayregistry quay -o yaml 2>/dev/null >&2 || true
  fi
}

function print_failing_pod_logs() {
  local ns="${QUAY_NS}"
  local name status restarts
  while read -r name _ status restarts _; do
    [[ -z "${name}" ]] && continue
    case "${status}" in
      CrashLoopBackOff|Error|ErrImagePull|ImagePullBackOff|CreateContainerConfigError|CreateContainerError|OOMKilled|Init:CrashLoopBackOff|Init:Error|Failed) ;;
      *) continue ;;
    esac
    echo "===== ${name} status=${status} restarts=${restarts} =====" >&2
    local containers
    containers=$(oc get pod "${name}" -n "${ns}" -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null || true)
    for container in ${containers}; do
      echo "----- ${name}/${container} (tail 80) -----" >&2
      oc logs "${name}" -n "${ns}" -c "${container}" --tail=80 2>&1 || true
      echo "----- ${name}/${container} previous (tail 40) -----" >&2
      oc logs "${name}" -n "${ns}" -c "${container}" --previous --tail=40 2>&1 || true
    done
  done < <(oc get pods -n "${ns}" --no-headers 2>/dev/null || true)
}

QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)

QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"

# IBM Cloud API key from the ibmcloud-quay cluster profile.
# This script deliberately runs without set -x and never prints the key.
IBMCLOUD_API_KEY_FILE="${CLUSTER_PROFILE_DIR}/ibmcloud-api-key"
if [[ ! -r "${IBMCLOUD_API_KEY_FILE}" ]]; then
  echo "ERROR: ${IBMCLOUD_API_KEY_FILE} not found or unreadable." >&2
  echo "       This step requires the ibmcloud-quay cluster profile, whose" >&2
  echo "       ibmcloud-api-key provides the credentials to create COS resources." >&2
  exit 1
fi
IBMCLOUD_API_KEY=$(cat "${IBMCLOUD_API_KEY_FILE}")
export IBMCLOUD_API_KEY

COS_REGION="${IBMCLOUD_COS_REGION}"

# COS bucket names are globally unique. Include CI identity plus randomness.
function new_cos_bucket_name() {
  local suffix
  suffix="${NAMESPACE:-ns}-${UNIQUE_HASH:-$(date +%s)}-${RANDOM}-$(date +%s)"
  suffix="$(printf '%s' "${suffix}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  printf 'quayprowci-%s\n' "${suffix}" | cut -c1-63
}

mkdir -p /tmp/QUAY_IBMCLOUD_COS && cd /tmp/QUAY_IBMCLOUD_COS

cat >>variables.tf <<EOF
variable "ibmcloud_api_key" {
  sensitive = true
}

variable "cos_region" {
  default = "us-south"
}

variable "cos_instance_name" {
  default = "quay-cos-instance"
}

variable "cos_bucket_name" {
  default = "quay-cos-bucket"
}

variable "resource_group" {
  default = "Default"
}
EOF

cat >>create_cos_bucket.tf <<EOF
terraform {
  required_providers {
    ibm = {
      source  = "IBM-Cloud/ibm"
      version = "~> 1.70"
    }
  }
}

provider "ibm" {
  ibmcloud_api_key = var.ibmcloud_api_key
  region           = var.cos_region
}

data "ibm_resource_group" "cos_group" {
  name = var.resource_group
}

resource "ibm_resource_instance" "cos_instance" {
  name              = var.cos_instance_name
  service           = "cloud-object-storage"
  plan              = "standard"
  location          = "global"
  resource_group_id = data.ibm_resource_group.cos_group.id
}

resource "ibm_cos_bucket" "quay_bucket" {
  bucket_name          = var.cos_bucket_name
  resource_instance_id = ibm_resource_instance.cos_instance.id
  region_location      = var.cos_region
  storage_class        = "smart"
}

resource "ibm_resource_key" "cos_hmac_key" {
  name                 = "\${var.cos_instance_name}-hmac"
  resource_instance_id = ibm_resource_instance.cos_instance.id
  role                 = "Writer"

  parameters = {
    HMAC = true
  }
}

output "cos_access_key" {
  value     = ibm_resource_key.cos_hmac_key.credentials["cos_hmac_keys.access_key_id"]
  sensitive = true
}

output "cos_secret_key" {
  value     = ibm_resource_key.cos_hmac_key.credentials["cos_hmac_keys.secret_access_key"]
  sensitive = true
}

output "cos_endpoint" {
  value = "s3.\${var.cos_region}.cloud-object-storage.appdomain.cloud"
}
EOF

terraform init
export TF_VAR_ibmcloud_api_key="${IBMCLOUD_API_KEY}"
export TF_VAR_cos_region="${COS_REGION}"

tf_apply_rc=1
for _ in 1 2 3 4 5; do
  QUAY_COS_BUCKET="$(new_cos_bucket_name)"
  COS_INSTANCE_NAME="quay-cos-${QUAY_COS_BUCKET##*-}"
  echo "IBM Cloud COS bucket name is ${QUAY_COS_BUCKET}"
  export TF_VAR_cos_bucket_name="${QUAY_COS_BUCKET}"
  export TF_VAR_cos_instance_name="${COS_INSTANCE_NAME}"
  tf_apply_rc=0
  terraform apply -auto-approve || tf_apply_rc=$?
  if [[ "${tf_apply_rc}" -eq 0 ]]; then
    break
  fi
  echo "terraform apply failed with exit code ${tf_apply_rc}; retrying with a new bucket name" >&2
  terraform destroy -auto-approve || true
done

printf '%s' "${QUAY_COS_BUCKET}" > "${SHARED_DIR}/QUAY_IBMCLOUD_COS_BUCKET"
printf '%s' "${COS_INSTANCE_NAME}" > "${SHARED_DIR}/QUAY_IBMCLOUD_COS_INSTANCE"
printf '%s' "${COS_REGION}" > "${SHARED_DIR}/QUAY_IBMCLOUD_COS_REGION"
tar -czf terraform.tgz --exclude=".terraform" *
cp terraform.tgz "${SHARED_DIR}/terraform.tgz"

if [[ "${tf_apply_rc}" -ne 0 ]]; then
  echo "terraform apply failed with exit code ${tf_apply_rc}" >&2
  exit "${tf_apply_rc}"
fi

# Disable tracing for sensitive credential handling
COS_ACCESS_KEY=$(terraform output -raw cos_access_key)
COS_SECRET_KEY=$(terraform output -raw cos_secret_key)
COS_ENDPOINT=$(terraform output -raw cos_endpoint)

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

QL_INSTALL_START="$(date +%s)"
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
  QL_INSTALL_STATUS="failed"
  QL_INSTALL_FAILURE="Timed out waiting for Quay Operator CSV to reach Succeeded phase"
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
  QL_INSTALL_STATUS="failed"
  QL_INSTALL_FAILURE="Timed out waiting for QuayRegistry CRD"
  echo "Timed out waiting for QuayRegistry CRD" >&2
  echo "=== Operator Pod Logs ===" >&2
  oc logs -n quay-enterprise -l name=quay-operator --tail=100 2>&1 || true
  echo "=== Events ===" >&2
  oc get events -n quay-enterprise --sort-by='.lastTimestamp' 2>&1 | tail -30 || true
  archive_pod_info
  exit 1
fi

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
    - IBMCloudStorage
    - access_key: $COS_ACCESS_KEY
      secret_key: $COS_SECRET_KEY
      bucket_name: $QUAY_COS_BUCKET
      hostname: $COS_ENDPOINT
      is_secure: true
      port: 443
      storage_path: /datastorage/registry
      maximum_chunk_size_mb: 100
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
FEATURE_MAILING: false
FEATURE_OTEL_TRACING: false
EOF

function merge_config_fragment() {
	local fragment="$1"
	if ! yq e 'true' "${fragment}" >/dev/null 2>&1; then
		echo "ERROR: ${fragment} is not valid YAML" >&2
		exit 1
	fi
	yq eval-all -i 'select(fileIndex == 0) *+ select(fileIndex == 1)' config.yaml "${fragment}"
}

if [[ -s "${SHARED_DIR}/quay-mail-config.yaml" ]]; then
	echo "Merging Mailpit config fragment into defaults..."
	merge_config_fragment "${SHARED_DIR}/quay-mail-config.yaml"
fi

if [[ -s "${SHARED_DIR}/quay-otel-config.yaml" ]]; then
	echo "Merging Jaeger/OTel config fragment into defaults..."
	merge_config_fragment "${SHARED_DIR}/quay-otel-config.yaml"
fi

DATABASE_CONFIG_FRAGMENT=""
for candidate in \
	"${SHARED_DIR}/quay-database-aws-rds-config.yaml" \
	"${SHARED_DIR}/quay-database-azure-postgres-config.yaml"
do
	if [[ -s "${candidate}" ]]; then
		DATABASE_CONFIG_FRAGMENT="${candidate}"
		break
	fi
done
POSTGRES_MANAGED="true"
if [[ -n "${DATABASE_CONFIG_FRAGMENT}" ]]; then
	echo "Merging unmanaged database config fragment ${DATABASE_CONFIG_FRAGMENT} into defaults..."
	merge_config_fragment "${DATABASE_CONFIG_FRAGMENT}"
	POSTGRES_MANAGED="false"
fi

if [[ -n "${QUAY_EXTRA_CONFIG:-}" ]]; then
	echo "Merging extra Quay config into defaults..."
	echo "${QUAY_EXTRA_CONFIG}" >extra_config.yaml
	merge_config_fragment extra_config.yaml
fi

yq -i '
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
		.SERVER_HOSTNAME,
		.PREFERRED_URL_SCHEME,
		.EXTERNAL_TLS_TERMINATION
	)
' config.yaml
if [[ "${POSTGRES_MANAGED}" == "true" ]]; then
	yq -i 'del(.DB_URI, .DB_CONNECTION_ARGS)' config.yaml
fi

TLS_MANAGED="true"
if [[ "${ENABLE_BUILD_SUPPORT:-false}" == "true" ]]; then
  echo "Build support enabled: configuring unmanaged TLS + virtual builder" >&2
  for f in config_builder.yaml ssl.cert ssl.key build_cluster.crt; do
    if [[ ! -s "${SHARED_DIR}/${f}" ]]; then
      echo "ERROR: ENABLE_BUILD_SUPPORT=true but ${SHARED_DIR}/${f} is missing." >&2
      echo "       Ensure quay-provisioning-tls and -builder ran first." >&2
      exit 1
    fi
  done
  TLS_MANAGED="false"
  cat "${SHARED_DIR}/config_builder.yaml" >> config.yaml

  if ! grep -qE '^ *BUILDER_CONTAINER_IMAGE: from-csv$' config.yaml; then
    echo "ERROR: config_builder.yaml has no 'BUILDER_CONTAINER_IMAGE: from-csv' line to fill" >&2
    QL_INSTALL_STATUS="failed"
    QL_INSTALL_FAILURE="config_builder.yaml has no builder image placeholder"
    exit 1
  fi
  csv_json=$(oc -n quay-enterprise get csv "$CSV" -o json)
  mapfile -t builder_images < <(jq -r '[.spec.install.spec.deployments[]?.spec.template.spec.containers[]?.env[]?
      | select(.name == "RELATED_IMAGE_COMPONENT_BUILDER") | .value // empty | select(. != "")]
      | unique | .[]' <<<"$csv_json")
  if [[ ${#builder_images[@]} -ne 1 ]]; then
    echo "ERROR: CSV ${CSV} must set exactly one non-empty RELATED_IMAGE_COMPONENT_BUILDER value; got: ${builder_images[*]:-none}" >&2
    QL_INSTALL_STATUS="failed"
    QL_INSTALL_FAILURE="Quay Operator CSV ${CSV} has no unique builder image"
    exit 1
  fi
  echo "Builder image from CSV ${CSV}: ${builder_images[0]}" >&2
  sed -i -E "s|^( *BUILDER_CONTAINER_IMAGE:) from-csv$|\1 ${builder_images[0]}|" config.yaml

  secret_args=(
    --from-file config.yaml=./config.yaml
    --from-file ssl.cert="${SHARED_DIR}/ssl.cert"
    --from-file ssl.key="${SHARED_DIR}/ssl.key"
    --from-file extra_ca_cert_build_cluster.crt="${SHARED_DIR}/build_cluster.crt"
  )
else
  secret_args=(--from-file config.yaml=./config.yaml)
fi

CONFIG_BUNDLE_SECRET_NAME="config-bundle-secret"

oc create secret generic -n quay-enterprise "${CONFIG_BUNDLE_SECRET_NAME}" "${secret_args[@]}"

echo "Creating Quay registry..." >&2
cat <<EOF | oc apply -f -
apiVersion: quay.redhat.com/v1
kind: QuayRegistry
metadata:
  name: quay
  namespace: quay-enterprise
spec:
  configBundleSecret: ${CONFIG_BUNDLE_SECRET_NAME}
  components:
  - kind: objectstorage
    managed: false
  - kind: monitoring
    managed: false
  - kind: postgres
    managed: ${POSTGRES_MANAGED}
  - kind: horizontalpodautoscaler
    managed: false
  - kind: quay
    managed: true
  - kind: mirror
    managed: true
  - kind: clair
    managed: true
  - kind: tls
    managed: ${TLS_MANAGED}
  - kind: route
    managed: true
EOF

echo "Waiting for Quay to become ready (timeout: 15m)..." >&2
for i in $(seq 1 90); do
  status="$(oc -n "${QUAY_NS}" get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [[ "$status" == "True" ]]; then
    echo "Quay is ready (after $((i * 10))s)" >&2
    QL_INSTALL_STATUS="passed"
    oc -n "${QUAY_NS}" get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
    oc get quayregistry quay -n "${QUAY_NS}" -o jsonpath='{.status.registryEndpoint}' > "$SHARED_DIR"/quayroute || true
    quay_route=$(oc get quayregistry quay -n "${QUAY_NS}" -o jsonpath='{.status.registryEndpoint}') || true
    quay_ca_bundle="$(mktemp)"
    if [[ -s /etc/pki/tls/certs/ca-bundle.crt ]]; then
      cat /etc/pki/tls/certs/ca-bundle.crt > "${quay_ca_bundle}"
    fi
    if [[ -s "${SHARED_DIR}/ssl.cert" ]]; then
      cat "${SHARED_DIR}/ssl.cert" >> "${quay_ca_bundle}"
    else
      ingress_cert_secret=$(oc -n openshift-ingress-operator get ingresscontroller default \
        -o jsonpath='{.spec.defaultCertificate.name}' 2>/dev/null || true)
      ingress_cert_secret="${ingress_cert_secret:-router-certs-default}"
      oc -n openshift-ingress get secret "${ingress_cert_secret}" \
        -o jsonpath='{.data.tls\.crt}' | base64 --decode >> "${quay_ca_bundle}"
    fi
    initialize_payload="$(mktemp)"
    chmod 600 "${initialize_payload}"
    jq -n --arg username "${QUAY_USERNAME}" --arg password "${QUAY_PASSWORD}" \
      --arg email "${QUAY_EMAIL}" \
      '{username: $username, password: $password, email: $email, access_token: true}' \
      > "${initialize_payload}"
    if ! curl --fail --silent --show-error --cacert "${quay_ca_bundle}" \
      -X POST "${quay_route}/api/v1/user/initialize" \
      --header 'Content-Type: application/json' --data-binary "@${initialize_payload}" \
      | jq -er '.access_token | select(type == "string" and length > 0)' \
          > "${SHARED_DIR}/quay_oauth2_token"; then
      echo "Failed to initialize the Quay user or obtain an access token" >&2
      exit 1
    fi
    chmod 600 "${SHARED_DIR}/quay_oauth2_token"
    rm -f "${initialize_payload}" "${quay_ca_bundle}"
    archive_pod_info
    exit 0
  fi
  if (( i % 6 == 0 )); then
    echo "[$((i * 10))s] Quay not ready yet. Component status:" >&2
    print_quayregistry_conditions
  fi
  sleep 10
done

echo "Timed out waiting for Quay to become ready" >&2
ql_conditions="$(oc -n "${QUAY_NS}" get quayregistry quay -o jsonpath='{.status.conditions}' 2>/dev/null || true)"
QL_INSTALL_STATUS="failed"
QL_INSTALL_FAILURE="Timed out waiting for Quay to become ready: ${ql_conditions}"
echo "Final QuayRegistry conditions:" >&2
print_quayregistry_conditions
echo "Pods in ${QUAY_NS} namespace:" >&2
oc -n "${QUAY_NS}" get pods -o wide >&2 || true
print_failing_pod_logs
echo "Events in ${QUAY_NS} namespace:" >&2
oc -n "${QUAY_NS}" get events --sort-by='.lastTimestamp' >&2 || true

oc -n "${QUAY_NS}" get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml" || true
oc -n "${QUAY_NS}" get pods -o yaml >"$ARTIFACT_DIR/quay-pods.yaml" || true
oc -n "${QUAY_NS}" get events --sort-by='.lastTimestamp' -o yaml >"$ARTIFACT_DIR/quay-events.yaml" || true
oc -n "${QUAY_NS}" get deployments -o yaml >"$ARTIFACT_DIR/quay-deployments.yaml" || true
archive_pod_info
exit 1
