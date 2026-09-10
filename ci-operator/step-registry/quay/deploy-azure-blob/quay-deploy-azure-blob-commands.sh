#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ "${MAP_TESTS}" = "true" ]; then
    exit_trap_ref="6263d6941034bf16cfc10b2bca7433ccf22fde60"
    exit_trap_sha256="bfc394cc4586576e2c0473d8a276ecb2fa456792fdd9114c23c1be54d9982305"
    exit_trap_script="$(mktemp)"
    exit_trap_url="https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/${exit_trap_ref}/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh"
    if command -v wget >/dev/null 2>&1; then
        wget -qO "${exit_trap_script}" "${exit_trap_url}"
    else
        curl -fsSL -o "${exit_trap_script}" "${exit_trap_url}"
    fi
    printf '%s  %s\n' "${exit_trap_sha256}" "${exit_trap_script}" | sha256sum --check --status
    eval "$(cat "${exit_trap_script}")"
    rm -f "${exit_trap_script}"
    trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--quay-tests__deploy-quay-azure__quay-tests-deploy-quay-azure.xml
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

# Derive the Playwright test ref from the deployed Quay app image so the e2e suite
# is version-matched to the product with no manual pin. The app image is pinned by
# digest; its source-commit label (org.opencontainers.image.revision / vcs-ref)
# points at the quay/quay commit it was built from. Written to
# ${SHARED_DIR}/playwright_git_ref for the test-e2e step; best-effort (the test step
# falls back to a branch if it is absent). This script runs without `set -x`, so the
# pull-secret authfile below is never traced; it is also removed immediately.
function derive_playwright_ref() {
  local ns="${QUAY_NS}"
  local app_img authfile commit
  app_img=$(oc -n "${ns}" get pods -l quay-component=quay-app \
    -o jsonpath='{.items[0].status.containerStatuses[?(@.name=="quay-app")].imageID}' 2>/dev/null || true)
  if [[ -z "${app_img}" ]]; then
    echo "WARNING: could not determine quay-app imageID; Playwright ref will fall back" >&2
    return 0
  fi
  echo "Deployed Quay app image: ${app_img}" >&2
  authfile=$(mktemp)
  oc get secret/pull-secret -n openshift-config \
    --template='{{index .data ".dockerconfigjson" | base64decode}}' > "${authfile}" 2>/dev/null || true
  commit=$(oc image info "${app_img}" --registry-config="${authfile}" -o json 2>/dev/null \
    | jq -r '.config.config.Labels["org.opencontainers.image.revision"] // .config.config.Labels["vcs-ref"] // ""' || true)
  rm -f "${authfile}"
  if [[ "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Derived Playwright git ref from deployed image: ${commit}" >&2
    echo "${commit}" > "${SHARED_DIR}/playwright_git_ref"
  else
    echo "WARNING: no 40-char source-commit label on deployed image (got '${commit}'); Playwright ref will fall back" >&2
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

#Get the credentials and Email of new Quay User
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
QUAY_EMAIL=$(cat /var/run/quay-qe-quay-secret/email)

QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"

# Azure service-principal credentials used by Terraform. Keep them in environment
# variables so they are not embedded in the Terraform source archived in SHARED_DIR.
# This script deliberately runs without set -x and never prints these values.
ARM_SUBSCRIPTION_ID=$(cat /var/run/quay-qe-azure-secret/subscription_id)
ARM_TENANT_ID=$(cat /var/run/quay-qe-azure-secret/tenant_id)
ARM_CLIENT_SECRET=$(cat /var/run/quay-qe-azure-secret/client_secret)
ARM_CLIENT_ID=$(cat /var/run/quay-qe-azure-secret/client_id)
export ARM_SUBSCRIPTION_ID ARM_TENANT_ID ARM_CLIENT_SECRET ARM_CLIENT_ID

# Azure storage-account names are globally unique, 3-24 characters, lowercase,
# and alphanumeric only. Include CI identity plus time/randomness and truncate.
function new_azure_storage_name() {
  local identity random_part suffix timestamp
  identity="${UNIQUE_HASH:-${NAMESPACE:-ns}}"
  identity="$(printf '%s' "${identity}" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  [[ -n "${identity}" ]] || identity="ns"
  identity="${identity}000"
  identity="${identity:0:3}"
  printf -v random_part '%05d' "${RANDOM}"
  timestamp="$(date +%s)"
  timestamp="${timestamp: -10}"
  suffix="${identity}${timestamp}${random_part}"
  printf 'quayci%s\n' "${suffix}" | cut -c1-24
}

mkdir -p QUAY_AZURE && cd QUAY_AZURE

cat >>variables.tf <<EOF
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

cat >>create_azure_storage_container.tf <<EOF
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
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
  storage_account_id    = azurerm_storage_account.quayazure.id
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
    queue = false
    table = false
    file  = false
  }

  start  = timestamp()
  expiry = timeadd(timestamp(), "8760h")

  permissions {
    read    = true
    write   = true
    delete  = true
    list    = true
    add     = true
    create  = true
    update  = true
    process = false
    tag     = false
    filter  = false
  }
}

output "sas_url_query_string" {
  value     = data.azurerm_storage_account_sas.quayazure.sas
  sensitive = true
}

output "primary_access_key" {
  value     = azurerm_storage_account.quayazure.primary_access_key
  sensitive = true
}
EOF

terraform init
tf_apply_rc=1
for _ in 1 2 3 4 5; do
  QUAY_AZURE_STORAGE_ID="$(new_azure_storage_name)"
  echo "Quay Azure storage account is ${QUAY_AZURE_STORAGE_ID}"
  export TF_VAR_resource_group="${QUAY_AZURE_STORAGE_ID}"
  export TF_VAR_storage_account="${QUAY_AZURE_STORAGE_ID}"
  export TF_VAR_storage_container="${QUAY_AZURE_STORAGE_ID}"
  tf_apply_rc=0
  terraform apply -auto-approve || tf_apply_rc=$?
  if [[ "${tf_apply_rc}" -eq 0 ]]; then
    break
  fi
  echo "terraform apply failed with exit code ${tf_apply_rc}; retrying with a new bucket name" >&2
  terraform destroy -auto-approve || true
done

# Share Terraform state and the storage ID for quay-deprovision. The archive is
# confined to SHARED_DIR and can contain sensitive Terraform state; do not print it.
printf '%s' "${QUAY_AZURE_STORAGE_ID}" > "${SHARED_DIR}/QUAY_AZURE_STORAGE_ID"
tar -czf terraform.tgz --exclude=".terraform" *
cp terraform.tgz "${SHARED_DIR}/terraform.tgz"

if [[ "${tf_apply_rc}" -ne 0 ]]; then
  echo "terraform apply failed with exit code ${tf_apply_rc}" >&2
  exit "${tf_apply_rc}"
fi

AZURE_ACCOUNT_KEY=$(terraform output -raw primary_access_key)
SAS_TOKEN=$(terraform output -raw sas_url_query_string)

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

#Deploy Quay, here disable monitoring component. Storage is unmanaged AzureStorage.
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
    - AzureStorage
    - azure_account_key: $AZURE_ACCOUNT_KEY
      azure_account_name: $QUAY_AZURE_STORAGE_ID
      azure_container: $QUAY_AZURE_STORAGE_ID
      sas_token: $SAS_TOKEN
      storage_path: /quayazuredata/quayregistry
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
	yq_version="v4.47.2"
	case "$(uname -m)" in
		x86_64) yq_arch="amd64"; yq_sha256="1bb99e1019e23de33c7e6afc23e93dad72aad6cf2cb03c797f068ea79814ddb0" ;;
		aarch64) yq_arch="arm64"; yq_sha256="05df1f6aed334f223bb3e6a967db259f7185e33650c3b6447625e16fea0ed31f" ;;
		*) echo "Unsupported architecture for yq: $(uname -m)" >&2; exit 1 ;;
	esac
	curl -fsSL "https://github.com/mikefarah/yq/releases/download/${yq_version}/yq_linux_${yq_arch}" -o /tmp/yq
	printf '%s  %s\n' "${yq_sha256}" /tmp/yq | sha256sum --check --status
	chmod +x /tmp/yq
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

  oc create secret generic -n quay-enterprise config-bundle-secret \
    --from-file config.yaml=./config.yaml \
    --from-file ssl.cert="${SHARED_DIR}/ssl.cert" \
    --from-file ssl.key="${SHARED_DIR}/ssl.key" \
    --from-file extra_ca_cert_build_cluster.crt="${SHARED_DIR}/build_cluster.crt"
else
  oc create secret generic -n quay-enterprise --from-file config.yaml=./config.yaml config-bundle-secret
fi

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
    derive_playwright_ref || true
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
