#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

: "${REQUESTER_EMAIL:?REQUESTER_EMAIL must be provided by ci-chat-bot}"
: "${ARO_HCP_DEPLOY_ENV:?ARO_HCP_DEPLOY_ENV must be provided}"

env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ ! -f "${env_file}" ]]; then
    printf 'Missing runtime lease export file: %s\n' "${env_file}" >&2
    exit 1
fi

# shellcheck disable=SC1090
source "${env_file}"

export VAULT_SECRET_PROFILE="${VAULT_SECRET_PROFILE:-dev}"

export LOCATION="${SELECTED_LOCATION:-${LOCATION:-}}"
: "${LOCATION:?LOCATION must be provided by SELECTED_LOCATION or the legacy runtime slot export file}"

config_file="${SHARED_DIR}/config.yaml"
if [[ ! -f "${config_file}" ]]; then
  printf 'Missing provisioned environment configuration: %s\n' "${config_file}" >&2
  exit 1
fi

REGIONAL_RESOURCE_GROUP="$(yq -r '.regionRG // ""' "${config_file}")"
: "${REGIONAL_RESOURCE_GROUP:?Regional resource group is missing from config.yaml}"

SVC_RESOURCE_GROUP="$(yq -r '.svc.rg // ""' "${config_file}")"
SVC_AKS_NAME="$(yq -r '.svc.aks.name // ""' "${config_file}")"
MGMT_RESOURCE_GROUP="$(yq -r '.mgmt.rg // ""' "${config_file}")"
MGMT_AKS_NAME="$(yq -r '.mgmt.aks.name // ""' "${config_file}")"
MGMT_STAMP_COUNT="$(yq -r '.mgmt.stamps.count // ""' "${config_file}")"

: "${SVC_RESOURCE_GROUP:?Missing .svc.rg in config.yaml}"
: "${SVC_AKS_NAME:?Missing .svc.aks.name in config.yaml}"
: "${MGMT_RESOURCE_GROUP:?Missing .mgmt.rg in config.yaml}"
: "${MGMT_AKS_NAME:?Missing .mgmt.aks.name in config.yaml}"
: "${MGMT_STAMP_COUNT:?Missing .mgmt.stamps.count in config.yaml}"

if [[ ! "${MGMT_STAMP_COUNT}" =~ ^[1-9][0-9]*$ ]]; then
  printf '.mgmt.stamps.count must be a positive integer\n' >&2
  exit 1
fi
if [[ "${MGMT_RESOURCE_GROUP}" != *-mgmt-1 ]]; then
  printf '.mgmt.rg must name stamp 1 and end in -mgmt-1\n' >&2
  exit 1
fi
if [[ "${MGMT_AKS_NAME}" != *-mgmt-1 ]]; then
  printf '.mgmt.aks.name must name stamp 1 and end in -mgmt-1\n' >&2
  exit 1
fi

MGMT_RESOURCE_GROUP_PREFIX="${MGMT_RESOURCE_GROUP%-1}"
MGMT_AKS_NAME_PREFIX="${MGMT_AKS_NAME%-1}"

MGMT_RESOURCE_GROUPS=()
MGMT_AKS_NAMES=()
for ((mgmt_stamp = 1; mgmt_stamp <= MGMT_STAMP_COUNT; mgmt_stamp++)); do
  MGMT_RESOURCE_GROUPS+=("${MGMT_RESOURCE_GROUP_PREFIX}-${mgmt_stamp}")
  MGMT_AKS_NAMES+=("${MGMT_AKS_NAME_PREFIX}-${mgmt_stamp}")
done

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export INFRA_SUBSCRIPTION_ID; INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-${ARO_HCP_DEPLOY_ENV}-subscription-id")
export DEPLOY_ENV="${ARO_HCP_DEPLOY_ENV}"

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none

unset GOFLAGS

# All resource lookups and role assignments use the infrastructure subscription.
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"

validate_resource_id() {
  local label="$1"
  local resource_id="$2"
  if [[ -z "${resource_id}" || "${resource_id}" == "None" || "${resource_id}" == "null" ]]; then
    printf 'Failed to resolve the %s resource ID from config.yaml\n' "${label}" >&2
    return 1
  fi
}

# Resolve every scope before granting any access.
REGIONAL_RESOURCE_GROUP_ID="$(az group show --name "${REGIONAL_RESOURCE_GROUP}" --query id --output tsv)"
validate_resource_id regional "${REGIONAL_RESOURCE_GROUP_ID}"
SVC_AKS_RESOURCE_ID="$(az aks show --resource-group "${SVC_RESOURCE_GROUP}" --name "${SVC_AKS_NAME}" --query id --output tsv)"
validate_resource_id svc "${SVC_AKS_RESOURCE_ID}"
MGMT_AKS_RESOURCE_IDS=()
for i in "${!MGMT_AKS_NAMES[@]}"; do
  aks_resource_id="$(az aks show --resource-group "${MGMT_RESOURCE_GROUPS[i]}" --name "${MGMT_AKS_NAMES[i]}" --query id --output tsv)"
  validate_resource_id "mgmt-$((i + 1))" "${aks_resource_id}"
  MGMT_AKS_RESOURCE_IDS+=("${aks_resource_id}")
done

# Guest users may have a tenant UPN that differs from their email address.
escaped_requester_email="${REQUESTER_EMAIL//\'/\'\'}"
REQUESTER_OBJECT_ID="$(
  az ad user list \
    --filter "userPrincipalName eq '${escaped_requester_email}' or mail eq '${escaped_requester_email}' or otherMails/any(m:m eq '${escaped_requester_email}')" \
    --query '[].id' \
    --output tsv
)"
if [[ ! "${REQUESTER_OBJECT_ID}" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; then
  printf 'Could not resolve a unique tenant user object ID for requester %s\n' "${REQUESTER_EMAIL}" >&2
  exit 1
fi

ensure_role_assignment() {
  local label="$1"
  local role="$2"
  local scope="$3"
  local existing_assignment_count

  existing_assignment_count="$(
    az role assignment list \
      --assignee-object-id "${REQUESTER_OBJECT_ID}" \
      --scope "${scope}" \
      --query "[?roleDefinitionName=='${role}' && scope=='${scope}'] | length(@)" \
      --output tsv
  )"
  if [[ ! "${existing_assignment_count}" =~ ^[0-9]+$ ]]; then
    printf 'Failed to check the %s role assignment state\n' "${label}" >&2
    return 1
  fi
  if (( existing_assignment_count == 0 )); then
    az role assignment create \
      --assignee-object-id "${REQUESTER_OBJECT_ID}" \
      --assignee-principal-type User \
      --role "${role}" \
      --scope "${scope}" \
      --output none
  fi
}

AKS_CLUSTER_ADMIN_ROLE="Azure Kubernetes Service RBAC Cluster Admin"
ensure_role_assignment regional Contributor "${REGIONAL_RESOURCE_GROUP_ID}"
ensure_role_assignment svc "${AKS_CLUSTER_ADMIN_ROLE}" "${SVC_AKS_RESOURCE_ID}"
for i in "${!MGMT_AKS_NAMES[@]}"; do
  ensure_role_assignment "mgmt-$((i + 1))" "${AKS_CLUSTER_ADMIN_ROLE}" "${MGMT_AKS_RESOURCE_IDS[i]}"
done

make -C dev-infrastructure/ svc.aks.kubeconfig.pipeline SVC_KUBECONFIG_FILE=../kubeconfig.svc DEPLOY_ENV="${DEPLOY_ENV}"

MGMT_KUBECONFIG_FILE="kubeconfig.mgmt"
rm -f "${MGMT_KUBECONFIG_FILE}"
for i in "${!MGMT_AKS_NAMES[@]}"; do
  az aks get-credentials \
    --overwrite-existing \
    --only-show-errors \
    -n "${MGMT_AKS_NAMES[i]}" \
    -g "${MGMT_RESOURCE_GROUPS[i]}" \
    -f "${MGMT_KUBECONFIG_FILE}"
done
kubelogin convert-kubeconfig -l azurecli --kubeconfig "${MGMT_KUBECONFIG_FILE}"

ACTUAL_MGMT_CONTEXTS="$(kubectl config get-contexts --kubeconfig "${MGMT_KUBECONFIG_FILE}" -o name)"
EXPECTED_MGMT_CONTEXTS_SORTED="$(printf '%s\n' "${MGMT_AKS_NAMES[@]}" | LC_ALL=C sort)"
ACTUAL_MGMT_CONTEXTS_SORTED="$(printf '%s\n' "${ACTUAL_MGMT_CONTEXTS}" | LC_ALL=C sort)"
if [[ "${ACTUAL_MGMT_CONTEXTS_SORTED}" != "${EXPECTED_MGMT_CONTEXTS_SORTED}" ]]; then
  printf 'Generated management kubeconfig does not contain exactly the expected AKS contexts\n' >&2
  exit 1
fi

kubectl config use-context "${MGMT_AKS_NAME}" --kubeconfig "${MGMT_KUBECONFIG_FILE}" >/dev/null

export KUBECONFIG=kubeconfig.svc
export AZURE_TOKEN_CREDENTIALS=prod
make frontend-grant-ingress DEPLOY_ENV="${DEPLOY_ENV}"

check_requester_aks_authorization() {
  local kubeconfig="$1"
  local context="$2"
  local resource verb group review remaining_seconds request_timeout

  # Check cluster-wide read access and a cluster-admin operation without mutations.
  for resource in nodes clusterrolebindings; do
    verb=list
    group=""
    if [[ "${resource}" == clusterrolebindings ]]; then
      verb=create
      group=rbac.authorization.k8s.io
    fi

    remaining_seconds=$((AKS_ACCESS_DEADLINE - SECONDS))
    if (( remaining_seconds <= 0 )); then
      return 1
    fi
    request_timeout=10
    if (( remaining_seconds < request_timeout )); then
      request_timeout="${remaining_seconds}"
    fi

    # Azure's authorizer identifies Entra users through extra.oid. A bare username
    # or kubectl --as does not supply this, and may bypass Azure authorization.
    # Submit as the provisioning identity; no requester credentials are needed.
    review="$(
      jq -n \
        --arg requester "${REQUESTER_OBJECT_ID}" \
        --arg verb "${verb}" --arg resource "${resource}" --arg group "${group}" \
        '{apiVersion: "authorization.k8s.io/v1", kind: "SubjectAccessReview",
          spec: {user: $requester, groups: ["system:authenticated"],
            extra: {oid: [$requester]},
            resourceAttributes: {verb: $verb, resource: $resource, group: $group}}}' |
        kubectl --kubeconfig "${kubeconfig}" --context "${context}" \
          --request-timeout="${request_timeout}s" create \
          --raw=/apis/authorization.k8s.io/v1/subjectaccessreviews -f -
    )" || {
      printf 'Failed to review requester authorization on %s\n' "${context}" >&2
      return 1
    }

    if ! jq -e '.status.allowed == true and .status.denied != true and
        ((.status.evaluationError // "") == "")' <<< "${review}" >/dev/null; then
      printf 'Requester cannot yet %s %s on %s\n' "${verb}" "${resource}" "${context}" >&2
      jq -c '.status // {}' <<< "${review}" >&2 || true
      return 1
    fi
  done
}

requester_has_aks_access() {
  local i
  check_requester_aks_authorization kubeconfig.svc "${SVC_AKS_NAME}" || return 1
  for i in "${!MGMT_AKS_NAMES[@]}"; do
    check_requester_aks_authorization "${MGMT_KUBECONFIG_FILE}" "${MGMT_AKS_NAMES[i]}" || return 1
  done
}

# ARM assignment visibility does not establish AKS authorization readiness.
# Poll every cluster's authorizer and fail closed on denials or review errors.
AKS_ACCESS_DEADLINE=$((SECONDS + 300))
while ! requester_has_aks_access; do
  remaining_seconds=$((AKS_ACCESS_DEADLINE - SECONDS))
  if (( remaining_seconds <= 0 )); then
    printf 'Requester AKS authorization was not ready within five minutes; kubeconfigs will not be published\n' >&2
    exit 1
  fi
  retry_delay=10
  if (( remaining_seconds < retry_delay )); then
    retry_delay="${remaining_seconds}"
  fi
  sleep "${retry_delay}"
done

# Publish the service kubeconfig last: cluster-bot uses it as the readiness signal.
cp "${MGMT_KUBECONFIG_FILE}" "${SHARED_DIR}"
cp kubeconfig.svc "${SHARED_DIR}"
