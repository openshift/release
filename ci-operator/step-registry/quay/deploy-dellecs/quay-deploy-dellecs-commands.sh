#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

command -v yq >/dev/null || { echo "yq not found in image ci/quay-test-omr; refusing to download at runtime" >&2; exit 1; }
command -v aws >/dev/null || { echo "aws CLI not found in image ci/quay-test-omr" >&2; exit 1; }

if [ "${MAP_TESTS}" = "true" ]; then
    # This helper executes with the step's mounted credentials. Fetch it from a
    # reviewed commit instead of another repository's mutable main branch, pin
    # the helper's own EnsureReqs download to the same commit, verify the
    # content, and source it. Update the commit and checksum deliberately.
    DELLECS_HELPER_COMMIT="be37e2f29a26c03f10dbcf27447f59db1df717bb"
    DELLECS_HELPER_SHA256="2c5f76741924960e8957be7a9206d8290b30a97225078fd338d3a46573aa5b93"
    DELLECS_HELPER_URL="https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/${DELLECS_HELPER_COMMIT}/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh"
    DELLECS_HELPER_FILE="$(mktemp)"
    curl -fsSL "${DELLECS_HELPER_URL}" -o "${DELLECS_HELPER_FILE}"
    # The helper evals EnsureReqs.sh from main; pin that reference too.
    sed -i "s|refs/heads/main|${DELLECS_HELPER_COMMIT}|g" "${DELLECS_HELPER_FILE}"
    DELLECS_HELPER_ACTUAL_SHA256="$(sha256sum "${DELLECS_HELPER_FILE}" | cut -d' ' -f1)"
    if [[ "${DELLECS_HELPER_ACTUAL_SHA256}" != "${DELLECS_HELPER_SHA256}" ]]; then
        echo "ERROR: ExitTrap helper checksum mismatch: ${DELLECS_HELPER_ACTUAL_SHA256}" >&2
        rm -f "${DELLECS_HELPER_FILE}"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "${DELLECS_HELPER_FILE}"
    rm -f "${DELLECS_HELPER_FILE}"
fi

# Tracks the Quay install for Sippy's quay-lifecycle suite. Empty
# QL_INSTALL_STATUS means the install was never attempted.
QL_INSTALL_START=""
QL_INSTALL_STATUS=""
QL_INSTALL_FAILURE=""

# shellcheck disable=SC2329 # invoked only from write_quay_install_junit, below
function ql_xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}

# shellcheck disable=SC2329 # invoked only from on_exit, below
function write_quay_install_junit() {
  local exit_code="$1"

  # No Subscription was ever created: an infra failure, not a Quay install attempt.
  if [[ -z "${QL_INSTALL_START}" ]]; then
    return 0
  fi

  # The install started but the script exited (e.g. a hard timeout kill) before
  # it recorded a result; that is still a failure, not a skip.
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

# shellcheck disable=SC2329 # invoked only via the EXIT trap installed below
function on_exit() {
  local ec=$?
  if [ "${MAP_TESTS}" = "true" ]; then
    LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
      ExitTrap--PostProcessPrep junit--quay-tests__deploy-quay-dellecs__quay-tests-deploy-quay-dellecs.xml || true
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

# Dell ECS bucket name. Derive it from the CI namespace assigned at runtime so a
# leaked bucket can be traced back to a job. ECS names must be lowercase and
# DNS-compatible. Retries add a suffix in case an earlier attempt with the same
# namespace left a bucket behind.
function new_dellecs_bucket_name() {
  local attempt="${1:-1}"
  local base
  base="${NAMESPACE:-${BUILD_ID:-${UNIQUE_HASH:-$(date +%s)}}}"
  base="$(printf '%s' "${base}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  base="${base#-}"
  base="${base%-}"
  [[ -n "${base}" ]] || base="quayprowci-$(date +%s)"
  # Leave room for the "quay-" prefix and a retry suffix (max 63 chars).
  base="${base:0:50}"
  base="${base%-}"
  if [[ "${attempt}" -gt 1 ]]; then
    base="${base}-${RANDOM}"
  fi
  printf 'quay-%s\n' "${base}"
}

QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"

# Dell ECS credentials. The secret has three fields: accesskey, secretkey, and
# endpoint. Do not echo them; this script runs without `set -x`.
QUAY_DELLECS_ACCESS_KEY=$(cat /var/run/quay-qe-dellecs-secret/accesskey)
QUAY_DELLECS_SECRET_KEY=$(cat /var/run/quay-qe-dellecs-secret/secretkey)
QUAY_DELLECS_ENDPOINT=$(cat /var/run/quay-qe-dellecs-secret/endpoint)
QUAY_DELLECS_REGION="${QUAY_DELLECS_REGION:-us-east-1}"

# Emit credentials as single-quoted YAML scalars. YAML treats values such as
# '*quay' or '&quay' as aliases/anchors unless they are quoted, and ECS access
# keys can contain those characters. Serialize instead of rejecting them.
function yaml_single_quote() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\'}"
}
QUAY_DELLECS_ACCESS_KEY_YAML="$(yaml_single_quote "${QUAY_DELLECS_ACCESS_KEY}")"
QUAY_DELLECS_SECRET_KEY_YAML="$(yaml_single_quote "${QUAY_DELLECS_SECRET_KEY}")"

export AWS_ACCESS_KEY_ID="${QUAY_DELLECS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_DELLECS_SECRET_KEY}"
export AWS_DEFAULT_REGION="${QUAY_DELLECS_REGION}"
export AWS_EC2_METADATA_DISABLED=true

# The ECS secret may carry an http:// endpoint, but this step uses TLS only.
# Normalize the endpoint to HTTPS: keep an explicit non-default port, map port
# 80 to 443, and default to 443 when no port is given. Quay's RadosGWStorage
# takes hostname/port/is_secure separately; the AWS CLI uses the full URL.
QUAY_DELLECS_IS_SECURE="true"
QUAY_DELLECS_HOST="${QUAY_DELLECS_ENDPOINT#http://}"
QUAY_DELLECS_HOST="${QUAY_DELLECS_HOST#https://}"
QUAY_DELLECS_HOST="${QUAY_DELLECS_HOST%/}"
QUAY_DELLECS_HOST="${QUAY_DELLECS_HOST%%/*}"
QUAY_DELLECS_PORT=""
# A bracketed IPv6 literal contains colons inside the brackets, so only split
# on the colon after the closing bracket.
if [[ "${QUAY_DELLECS_HOST}" == \[*\]:* ]]; then
  QUAY_DELLECS_PORT="${QUAY_DELLECS_HOST##*]:}"
  QUAY_DELLECS_HOST="${QUAY_DELLECS_HOST%]:*}]"
elif [[ "${QUAY_DELLECS_HOST}" != \[* && "${QUAY_DELLECS_HOST}" == *:* ]]; then
  QUAY_DELLECS_PORT="${QUAY_DELLECS_HOST##*:}"
  QUAY_DELLECS_HOST="${QUAY_DELLECS_HOST%:*}"
fi
if [[ -z "${QUAY_DELLECS_PORT}" || "${QUAY_DELLECS_PORT}" == "80" ]]; then
  QUAY_DELLECS_PORT="443"
fi
if [[ "${QUAY_DELLECS_PORT}" == "443" ]]; then
  QUAY_DELLECS_ENDPOINT="https://${QUAY_DELLECS_HOST}"
else
  QUAY_DELLECS_ENDPOINT="https://${QUAY_DELLECS_HOST}:${QUAY_DELLECS_PORT}"
fi

# Persist the endpoint and region before creating anything, so the post-phase
# deprovision can clean up even if this step is killed mid-create.
echo "${QUAY_DELLECS_ENDPOINT}" > "${SHARED_DIR}/QUAY_DELLECS_ENDPOINT"
echo "${QUAY_DELLECS_REGION}" > "${SHARED_DIR}/QUAY_DELLECS_REGION"

# Record every candidate name before attempting it. create-bucket can succeed
# server-side and still return an error (for example, the response is lost), so
# a failed attempt may have created a bucket that cleanup must delete.
QUAY_DELLECS_BUCKETS_FILE="${SHARED_DIR}/QUAY_DELLECS_BUCKETS"
: > "${QUAY_DELLECS_BUCKETS_FILE}"

# Create the bucket with the AWS CLI. This lane does not use Terraform.
bucket_rc=1
for attempt in 1 2 3 4 5; do
  QUAY_DELLECS_BUCKET="$(new_dellecs_bucket_name "${attempt}")"
  printf '%s\n' "${QUAY_DELLECS_BUCKET}" >> "${QUAY_DELLECS_BUCKETS_FILE}"
  echo "quay Dell ECS bucket name is ${QUAY_DELLECS_BUCKET}"
  bucket_rc=0
  aws --endpoint-url "${QUAY_DELLECS_ENDPOINT}" --region "${QUAY_DELLECS_REGION}" \
    s3api create-bucket --bucket "${QUAY_DELLECS_BUCKET}" || bucket_rc=$?
  if [[ "${bucket_rc}" -eq 0 ]]; then
    break
  fi
  echo "Dell ECS bucket creation failed with exit code ${bucket_rc}; retrying with a new name" >&2
done

if [[ "${bucket_rc}" -ne 0 ]]; then
  echo "Dell ECS bucket creation failed with exit code ${bucket_rc}" >&2
  exit "${bucket_rc}"
fi

# Persist the successful bucket for readers that only need one name.
echo "${QUAY_DELLECS_BUCKET}" > "${SHARED_DIR}/QUAY_DELLECS_BUCKET"

aws --endpoint-url "${QUAY_DELLECS_ENDPOINT}" --region "${QUAY_DELLECS_REGION}" \
  s3api head-bucket --bucket "${QUAY_DELLECS_BUCKET}"

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

#Deploy Quay, here disable monitoring component
cat >>config.yaml <<EOF
CREATE_PRIVATE_REPO_ON_PUSH: true
CREATE_NAMESPACE_ON_PUSH: true
FEATURE_EXTENDED_REPOSITORY_NAMES: true
FEATURE_QUOTA_MANAGEMENT: true
FEATURE_AUTO_PRUNE: true
FEATURE_PROXY_CACHE: true
PERMANENTLY_DELETE_TAGS: true
RESET_CHILD_MANIFEST_EXPIRATION: true
FEATURE_PROXY_STORAGE: true
FEATURE_SUPERUSER_CONFIGDUMP: true
FEATURE_UI_V2: true
FEATURE_SUPERUSERS_FULL_ACCESS: true
FEATURE_UI_MODELCARD: true
USERFILES_LOCATION: default
USERFILES_PATH: userfiles/
DISTRIBUTED_STORAGE_DEFAULT_LOCATIONS:
  - default
DISTRIBUTED_STORAGE_PREFERENCE:
  - default
# Dell ECS is S3-compatible; RadosGWStorage is Quay's generic S3-compatible
# driver (S3Storage ignores a custom endpoint when s3_region is set).
DISTRIBUTED_STORAGE_CONFIG:
  default:
    - RadosGWStorage
    - access_key: $QUAY_DELLECS_ACCESS_KEY_YAML
      secret_key: $QUAY_DELLECS_SECRET_KEY_YAML
      bucket_name: $QUAY_DELLECS_BUCKET
      hostname: $QUAY_DELLECS_HOST
      is_secure: $QUAY_DELLECS_IS_SECURE
      port: "$QUAY_DELLECS_PORT"
      region_name: $QUAY_DELLECS_REGION
      storage_path: /quay
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

# Merge a config fragment into config.yaml. Validate first so a
# present-but-malformed fragment fails the step clearly instead of corrupting
# config.yaml. Service fragments use list-append semantics ('*+'). Callers that
# promise explicit overrides pass list_mode=replace ('*') so a supplied list
# replaces the default instead of extending it.
function merge_config_fragment() {
	local fragment="$1"
	local list_mode="${2:-append}"
	if ! yq e 'true' "${fragment}" >/dev/null 2>&1; then
		echo "ERROR: ${fragment} is not valid YAML" >&2
		exit 1
	fi
	local merge_op='*+'
	if [[ "${list_mode}" == 'replace' ]]; then
		merge_op='*'
	fi
	yq eval-all -i "select(fileIndex == 0) ${merge_op} select(fileIndex == 1)" config.yaml "${fragment}"
}

# Merge order: Mailpit -> OTel -> unmanaged database -> QUAY_EXTRA_CONFIG,
# so an explicit override still wins over the service-owned fragments. Service
# fragments append list values; QUAY_EXTRA_CONFIG replaces them. A missing
# fragment is a silent no-op, leaving the disabled default above.
if [[ -s "${SHARED_DIR}/quay-mail-config.yaml" ]]; then
	echo "Merging Mailpit config fragment into defaults..."
	merge_config_fragment "${SHARED_DIR}/quay-mail-config.yaml"
fi

if [[ -s "${SHARED_DIR}/quay-otel-config.yaml" ]]; then
	echo "Merging Jaeger/OTel config fragment into defaults..."
	merge_config_fragment "${SHARED_DIR}/quay-otel-config.yaml"
fi

# Unmanaged DB fragments from quay-database-intg-* steps. At most one should
# exist; the first match wins.
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
	merge_config_fragment extra_config.yaml replace
fi

# Strip field-group keys for components this CR keeps managed. The operator
# injects those values; leaving them in configBundleSecret blocks rollout.
# Keep DB_URI / DB_CONNECTION_ARGS when an unmanaged database fragment was
# merged above; otherwise strip them so the operator manages postgres.
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

# Build support requires unmanaged TLS plus a virtual builder. When enabled, the
# quay-provisioning-{tls,builder} steps have already written the
# cert/key, build-cluster CA, and builder config to SHARED_DIR. Fold the builder
# config into the bundle (after the extra-config merge, so it is not stripped) and
# hand the operator the unmanaged cert material. Do not echo config_builder.yaml:
# it carries the Quay password and builder SA token. (This script runs without
# set -x, so the append below is not traced.)
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

  # The builder images are always the RELATED_IMAGE_COMPONENT_BUILDER{,_QEMU}
  # the Subscription's installed CSV ships, so the builder matches the installed
  # operator. quay-provisioning-builder leaves "from-csv" (kubernetesPodman) or
  # "from-csv-qemu" (kubernetes) for them. No fallback.
  if ! grep -qE '^ *(BUILDER_CONTAINER_IMAGE: from-csv|BUILDER_VM_CONTAINER_IMAGE: from-csv-qemu)$' config.yaml; then
    echo "ERROR: config_builder.yaml has no 'BUILDER_CONTAINER_IMAGE: from-csv' or 'BUILDER_VM_CONTAINER_IMAGE: from-csv-qemu' line to fill" >&2
    QL_INSTALL_STATUS="failed"
    QL_INSTALL_FAILURE="config_builder.yaml has no builder image placeholder"
    exit 1
  fi
  csv_json=$(oc -n quay-enterprise get csv "$CSV" -o json)
  # Prints the unique non-empty values the CSV's deployments set for env var $1.
  function csv_env_values() {
    jq -r --arg name "$1" '[.spec.install.spec.deployments[]?.spec.template.spec.containers[]?.env[]?
        | select(.name == $name) | .value // empty | select(. != "")]
        | unique | .[]' <<<"$csv_json"
  }
  mapfile -t builder_images < <(csv_env_values RELATED_IMAGE_COMPONENT_BUILDER)
  if [[ ${#builder_images[@]} -ne 1 ]]; then
    echo "ERROR: CSV ${CSV} must set exactly one non-empty RELATED_IMAGE_COMPONENT_BUILDER value; got: ${builder_images[*]:-none}" >&2
    QL_INSTALL_STATUS="failed"
    QL_INSTALL_FAILURE="Quay Operator CSV ${CSV} has no unique builder image"
    exit 1
  fi
  echo "Builder image from CSV ${CSV}: ${builder_images[0]}" >&2
  sed -i -E "s|^( *BUILDER_CONTAINER_IMAGE:) from-csv$|\1 ${builder_images[0]}|" config.yaml

  if grep -qE '^ *BUILDER_VM_CONTAINER_IMAGE: from-csv-qemu$' config.yaml; then
    mapfile -t qemu_images < <(csv_env_values RELATED_IMAGE_COMPONENT_BUILDER_QEMU)
    if [[ ${#qemu_images[@]} -ne 1 ]]; then
      echo "ERROR: CSV ${CSV} must set exactly one non-empty RELATED_IMAGE_COMPONENT_BUILDER_QEMU value; got: ${qemu_images[*]:-none}" >&2
      QL_INSTALL_STATUS="failed"
      QL_INSTALL_FAILURE="Quay Operator CSV ${CSV} has no unique builder VM image"
      exit 1
    fi
    QEMU_IMAGE="${qemu_images[0]}"
    echo "Builder VM image from CSV ${CSV}: ${QEMU_IMAGE}" >&2
    sed -i -E "s|^( *BUILDER_VM_CONTAINER_IMAGE:) from-csv-qemu$|\1 ${QEMU_IMAGE}|" config.yaml
  fi

  secret_args=(
    --from-file config.yaml=./config.yaml
    --from-file ssl.cert="${SHARED_DIR}/ssl.cert"
    --from-file ssl.key="${SHARED_DIR}/ssl.key"
    --from-file extra_ca_cert_build_cluster.crt="${SHARED_DIR}/build_cluster.crt"
  )
else
  secret_args=(--from-file config.yaml=./config.yaml)
fi

# configBundleSecret name. The GCP SQL handling (client certs in the bundle
# and the postgresql-client-certs name) returns with the GCP database lane.
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

# Verify a Quay user's password through the signin API. Used when a create
# response is ambiguous: the user may already exist because the server created it
# before the connection failed. Signin success proves the expected credentials
# work; an existing username alone does not.
function quay_user_login_ok() {
  local host="$1" user="$2" password="$3"
  local cookies csrf code
  cookies=$(mktemp)
  csrf=$(curl -sk -c "${cookies}" "https://${host}/csrf_token" | jq -r '.csrf_token // empty' || true)
  code=$(jq -n --arg u "${user}" --arg p "${password}" '{username: $u, password: $p}' |
    curl -sk -o /dev/null -w '%{http_code}' -c "${cookies}" -b "${cookies}" \
      -X POST "https://${host}/api/v1/signin" \
      -H "X-CSRF-Token: ${csrf}" -H 'Content-Type: application/json' --data @- || true)
  rm -f "${cookies}"
  [[ "${code}" == "200" ]]
}

# The kubernetes executor's VM has no cluster pull secret or mirror config. It
# logs in to the WORKER_IMAGE registry as QUAY_USERNAME and runs
# WORKER_IMAGE:WORKER_TAG, which quay-provisioning-builder points at a throwaway
# user of this Quay. Create that user, copy the CSV's builder image there, and
# pre-pull the VM image on every worker for IMAGE_PULL_POLICY IfNotPresent.
function prepare_qemu_worker() {
  [[ -n "${QEMU_IMAGE:-}" ]] || return 0
  local executor='.BUILD_MANAGER[1].EXECUTORS[0]' worker host user password
  local cookies response csrf code="" authfile arch src mirrored="" node
  worker="$(yq e "${executor}.WORKER_IMAGE" config.yaml):$(yq e "${executor}.WORKER_TAG" config.yaml)"
  user=$(yq e "${executor}.QUAY_USERNAME" config.yaml)
  password=$(yq e "${executor}.QUAY_PASSWORD" config.yaml)
  host=${worker%%/*}
  if [[ "https://${host}" != "$(cat "${SHARED_DIR}/quayroute")" ]]; then
    echo "ERROR: WORKER_IMAGE host ${host} is not the Quay route $(cat "${SHARED_DIR}/quayroute")" >&2
    return 1
  fi

  # Quay rejects session POSTs without a CSRF token. Retry while the route
  # settles. If a create response is lost after the user was created, retries
  # get a duplicate-user error; verify the expected credentials with signin
  # before proceeding so an existing username alone is not treated as success.
  cookies=$(mktemp)
  response=$(mktemp)
  user_ready=false
  for _ in $(seq 1 12); do
    csrf=$(curl -sk -c "${cookies}" "https://${host}/csrf_token" | jq -r '.csrf_token // empty' || true)
    code=$(jq -n --arg u "${user}" --arg p "${password}" '{username: $u, password: $p, email: ($u + "@example.com")}' |
      curl -sk -o "${response}" -w '%{http_code}' -X POST "https://${host}/api/v1/user/" \
        -b "${cookies}" -H "X-CSRF-Token: ${csrf}" -H 'Content-Type: application/json' --data @- || true)
    if [[ "${code}" == "200" ]]; then
      user_ready=true
      break
    fi
    if quay_user_login_ok "${host}" "${user}" "${password}"; then
      echo "Quay user ${user} already exists; verified its credentials" >&2
      user_ready=true
      break
    fi
    sleep 10
  done
  if [[ "${user_ready}" != "true" ]]; then
    echo "ERROR: creating Quay user ${user} returned HTTP ${code}: $(cat "${response}")" >&2
    rm -f "${cookies}" "${response}"
    return 1
  fi
  rm -f "${cookies}" "${response}"
  echo "Quay user ${user} is ready for the builder VM" >&2

  # oc image mirror does not read the cluster's ImageDigestMirrorSets (a nightly
  # CSV's registry.redhat.io/quay digests live on registry.stage.redhat.io), so
  # try each mirror of the image before the image itself.
  authfile=$(mktemp)
  oc -n openshift-config get secret pull-secret -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d |
    jq --arg h "${host}" --arg a "$(printf '%s:%s' "${user}" "${password}" | base64 -w0)" \
      '.auths[$h] = {auth: $a}' >"${authfile}"
  arch=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[0].status.nodeInfo.architecture}')
  for src in $(oc get imagedigestmirrorset -o json | jq -r --arg img "${builder_images[0]}" '
      .items[].spec.imageDigestMirrors[]? | .source as $s
      | select(($img | startswith($s + "/")) or ($img | startswith($s + "@")))
      | .mirrors[]? + ($img | ltrimstr($s))') "${builder_images[0]}"; do
    if oc image mirror -a "${authfile}" --insecure=true --filter-by-os="linux/${arch}" "${src}" "${worker}"; then
      mirrored="${src}"
      break
    fi
  done
  rm -f "${authfile}"
  if [[ -z "${mirrored}" ]]; then
    echo "ERROR: could not copy ${builder_images[0]} to ${worker}" >&2
    return 1
  fi
  echo "Copied builder image ${mirrored} to ${worker}" >&2

  # The kubeconfig sets no namespace, so without -n oc debug looks up the CI
  # pod's own namespace, which does not exist on this cluster.
  for node in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do
    echo "Pre-pulling ${QEMU_IMAGE} on ${node}" >&2
    oc debug -n default "node/${node}" -- chroot /host podman pull -q --authfile /var/lib/kubelet/config.json "${QEMU_IMAGE}" >&2
  done
}

echo "Waiting for Quay to become ready (timeout: 15m)..." >&2
for i in $(seq 1 90); do
  status="$(oc -n "${QUAY_NS}" get quayregistry quay -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  if [[ "$status" == "True" ]]; then
    echo "Quay is ready (after $((i * 10))s)" >&2
    QL_INSTALL_STATUS="passed"
    oc -n "${QUAY_NS}" get quayregistries -o yaml >"$ARTIFACT_DIR/quayregistries.yaml"
    oc get quayregistry quay -n "${QUAY_NS}" -o jsonpath='{.status.registryEndpoint}' > "$SHARED_DIR"/quayroute || true
    archive_pod_info
    prepare_qemu_worker
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

