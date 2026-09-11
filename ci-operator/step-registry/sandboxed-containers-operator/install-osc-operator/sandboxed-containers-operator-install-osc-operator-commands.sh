#!/usr/bin/env bash
#
# Install OSC (OpenShift Sandboxed Containers) Operator
#
# This script installs and configures the OSC operator and operands using
# helm charts cloned from OSC_CHARTS_REPO.
# Requires ci/rhdh-e2e-runner base image (provides helm, oc, git, jq).
#
# Environment Variables:
#   OSC_INSTALL                   - "true" to install, "false" to skip (default: false)
#   OSC_NAMESPACE                 - Namespace for operator (default: openshift-sandboxed-containers-operator)
#   CATALOG_SOURCE_IMAGE      - Custom catalog image (optional)
#   OSC_CHARTS_REPO               - Charts repo URL
#   OSC_CHARTS_REF                - Charts git ref (default: main)
#   ENABLEPEERPODS                - "true" to enable peer-pods (default: false)
#   WORKLOAD_TO_TEST              - "kata", "peer-pods", or "coco" (default: kata)
#
# Outputs:
#   Patches osc-config ConfigMap in default namespace to indicate installation complete.
#

set -euo pipefail

#========================================
# Configuration
#========================================

export SHARED_DIR=${SHARED_DIR:-/tmp}
export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}

OSC_INSTALL=${OSC_INSTALL:-false}
OSC_NAMESPACE=${OSC_NAMESPACE:-openshift-sandboxed-containers-operator}
CATALOG_SOURCE_IMAGE=${CATALOG_SOURCE_IMAGE:-}
OSC_CHARTS_REPO=${OSC_CHARTS_REPO:-https://github.com/confidential-devhub/charts.git}
OSC_CHARTS_REF=${OSC_CHARTS_REF:-main}
ENABLEPEERPODS=${ENABLEPEERPODS:-false}
WORKLOAD_TO_TEST=${WORKLOAD_TO_TEST:-kata}
OSC_DEV_CATALOG_NAME="osc-operator-dev-catalog"

OC_RETRY_COUNT=${OC_RETRY_COUNT:-3}
OC_RETRY_INTERVAL=${OC_RETRY_INTERVAL:-20}


# Early exit if installation disabled
if [[ "${OSC_INSTALL}" != "true" ]]; then
  echo ">>> Skipping OSC operator installation (OSC_INSTALL=${OSC_INSTALL})"
  exit 0
fi

# Verify helm is available (pre-installed in base image)
if ! command -v helm &> /dev/null; then
  echo ">>> ERROR: helm not found in base image"
  exit 1
fi

# Show configuration
echo ">>> OSC charts: ${OSC_CHARTS_REPO} (ref: ${OSC_CHARTS_REF})"
echo ">>> Namespace: ${OSC_NAMESPACE}"
echo ">>> Workload: ${WORKLOAD_TO_TEST}"
echo ">>> Peer-pods: ${ENABLEPEERPODS}"
if [[ -n "${CATALOG_SOURCE_IMAGE}" ]]; then
  echo ">>> Catalog source: ${OSC_DEV_CATALOG_NAME} (image: ${CATALOG_SOURCE_IMAGE})"
else
  echo ">>> Catalog source: redhat-operators (using existing catalog)"
fi

SCRATCH=$(mktemp -d)
cd "${SCRATCH}"

function exit_handler() {
  local exitcode=$?
  set +e
  rm -rf "${SCRATCH}"

  if [[ ${exitcode} -ne 0 ]]; then
    echo ">>> ERROR: OSC operator installation failed"
    echo ">>> Namespace status:"
    oc get all -n "${OSC_NAMESPACE}" || true
    echo ">>> Operator logs:"
    oc logs -n "${OSC_NAMESPACE}" deployment/controller-manager --tail=50 || true
  fi
}
trap 'exit_handler' EXIT


function retry() {
  "$@" && return 0
  for (( i = 0; i < 9; i++ )); do
    sleep 30
    "$@" && return 0
  done
  return 1
}

function wait_until() {
  local description="$1"
  local timeout_seconds="$2"
  local check_interval="$3"
  local condition_command="$4"

  local max_iterations=$((timeout_seconds / check_interval))
  local progress_interval=$((60 / check_interval))
  [[ ${progress_interval} -lt 1 ]] && progress_interval=1

  echo ">>> Waiting for ${description} (timeout: ${timeout_seconds}s, interval: ${check_interval}s)..." >&2

  for (( i = 1; i <= max_iterations; i++ )); do
    if eval "${condition_command}" 2>/dev/null; then
      echo ">>> ${description} - SUCCESS (after $((i * check_interval))s)" >&2
      return 0
    fi

    if [[ $((i % progress_interval)) -eq 0 ]]; then
      echo ">>> Still waiting for ${description} (${i}/${max_iterations}, $((i * check_interval))s elapsed)..." >&2
    fi

    [[ ${i} -lt ${max_iterations} ]] && sleep "${check_interval}"
  done

  echo ">>> ERROR: ${description} - TIMEOUT after ${timeout_seconds}s" >&2
  return 1
}


# Usage: oc_with_retry [--retries N] [--interval S] command [args...]
function oc_with_retry() {
  local max_attempts=${OC_RETRY_COUNT}
  local interval=${OC_RETRY_INTERVAL}
  while [[ "$1" == --* ]]; do
    case "$1" in
      --retries)  max_attempts="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local err_file
  err_file=$(mktemp)
  for (( attempt = 1; attempt <= max_attempts; attempt++ )); do
    if "$@" 2>"${err_file}"; then
      rm -f "${err_file}"
      return 0
    fi

    local err_output
    err_output=$(cat "${err_file}")

    if echo "${err_output}" | grep -qiE 'Unable to connect|connection refused|dial tcp|i/o timeout|EOF|network is unreachable|TLS handshake timeout'; then
      echo ">>> Connection error (attempt ${attempt}/${max_attempts}): ${err_output}" >&2
      [[ ${attempt} -lt ${max_attempts} ]] && sleep "${interval}" && continue
      rm -f "${err_file}"
      echo ">>> ERROR: Cannot reach cluster after ${max_attempts} attempts" >&2
      return 1
    fi

    rm -f "${err_file}"
    local safe_cmd
    safe_cmd=$(echo "$*" | sed -E 's/(--from-literal=[^ =]+=)[^ ]*/\1<REDACTED>/g')
    echo ">>> ERROR: Command failed: ${safe_cmd}" >&2
    echo "${err_output}" >&2
    return 1
  done
}

function mirror_konflux() {
  echo ">>> Create mirror for konflux images"
  oc_with_retry oc apply -f "https://raw.githubusercontent.com/openshift/sandboxed-containers-operator/refs/heads/devel/.tekton/images-mirror-set.yaml"
  oc_with_retry oc apply -f "https://raw.githubusercontent.com/openshift/trustee-fbc/refs/heads/main/.tekton/images-mirror-set.yaml"

  echo ">>> Waiting for MachineConfigPools to begin updating..."
  sleep 30

  if ! wait_until "all MachineConfigPools updated" 1800 30 \
    "oc wait mcp --all --for=condition=Updated --timeout=0s 2>/dev/null"; then
    echo ">>> ERROR: MachineConfigPools did not settle after 30 minutes"
    oc get mcp || true
    return 1
  fi
}

function latest_catsrc_image_tag() {
    local api_url="https://quay.io/api/v1/repository/redhat-user-workloads/ose-osc-tenant/osc-test-fbc/tag/"
    local page=1
    local max_pages=20

    while [ "$page" -le "$max_pages" ]; do
        local resp
        resp=$(curl -sf --max-time 30 "${api_url}?limit=100&page=${page}&onlyActiveTags=true") || resp=""

        if [ -z "$resp" ] || ! jq -e '.tags | length > 0' <<< "$resp" >/dev/null 2>&1; then
            break
        fi

        local first_match
        first_match=$(echo "$resp" | \
            jq -r '.tags[]? | select(.name | test("^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$")) | .name' | head -1)

        if [ -n "$first_match" ]; then
            echo "$first_match"
            return 0
        fi

        ((page++))
    done

    if [ "$page" -gt "$max_pages" ]; then
        echo "ERROR: Hit max_pages ($max_pages) limit while searching for tags." >&2
    fi

    echo "WARNING: No X.Y.Z-unix_epoch tag found, using :latest" >&2
    echo "latest"
}

function setup_catalog_source() {
  if [[ -z "${CATALOG_SOURCE_IMAGE}" ]]; then
    echo ">>> No CATALOG_SOURCE_IMAGE set, using existing redhat-operators catalog"
    return 0
  fi

  echo ">>> Setting up catalog source image for Pre-GA install"

  mirror_konflux

  local default_catsrc_image="quay.io/redhat-user-workloads/ose-osc-tenant/osc-test-fbc"
  if [[ "${CATALOG_SOURCE_IMAGE}" = "${default_catsrc_image}:latest" ]]; then
    local catsrc_image_tag
    catsrc_image_tag=$(latest_catsrc_image_tag)
    CATALOG_SOURCE_IMAGE="${default_catsrc_image}:${catsrc_image_tag}"
    echo ">>> Resolved :latest to tag: ${catsrc_image_tag}"
  else
    echo ">>> Using provided catalog image: ${CATALOG_SOURCE_IMAGE}"
  fi

  echo "CATALOG_SOURCE_IMAGE=${CATALOG_SOURCE_IMAGE}" > "${SHARED_DIR}/catalog-source-image.env"
  echo ">>> Saved resolved CATALOG_SOURCE_IMAGE to ${SHARED_DIR}/catalog-source-image.env"
  echo ">>> Helm chart will create CatalogSource ${OSC_DEV_CATALOG_NAME} with this image"

  # Update osc-config ConfigMap with the chart's catalog name
  if oc get configmap osc-config -n default &>/dev/null; then
    oc_with_retry oc patch configmap osc-config -n default --type merge \
      -p "{\"data\":{\"catalogsourcename\":\"${OSC_DEV_CATALOG_NAME}\"}}"
    echo ">>> Patched osc-config with catalogsourcename=${OSC_DEV_CATALOG_NAME}"
  fi
}

function fetch_osc_charts() {
  local charts_dir="${SCRATCH}/charts"

  echo ">>> Fetching OSC charts from: ${OSC_CHARTS_REPO} (ref: ${OSC_CHARTS_REF})" >&2

  rm -rf "${charts_dir}"
  git init --quiet "${charts_dir}"
  git -C "${charts_dir}" remote add origin "${OSC_CHARTS_REPO}"
  if ! git -C "${charts_dir}" fetch --depth 1 origin "${OSC_CHARTS_REF}"; then
    echo ">>> ERROR: Failed to fetch ${OSC_CHARTS_REF} from charts repository" >&2
    return 1
  fi
  git -C "${charts_dir}" checkout --quiet FETCH_HEAD

  echo ">>> Charts fetched" >&2
  local result_dir
  if [[ -d "${charts_dir}/charts" ]]; then
    result_dir="${charts_dir}/charts"
  else
    result_dir="${charts_dir}"
  fi

  echo "${result_dir}"
}

function get_cloud_provider() {
  local provider
  provider=$(oc_with_retry oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.type}') || return 1
  provider=$(echo "${provider}" | tr '[:upper:]' '[:lower:]')
  if [[ -z "${provider}" ]]; then
    echo ">>> ERROR: could not determine cluster platform type" >&2
    return 1
  fi
  if [[ "${provider}" == "none" ]]; then
    provider="libvirt"
  fi
  echo "${provider}"
}

function setup_aws_peerpods() {
  echo ">>> Detecting AWS peer-pods configuration from cluster" >&2
  
  # Get AWS credentials
  oc -n kube-system get secret aws-creds -o json > aws-creds.json || return 1
  
  local AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  AWS_ACCESS_KEY_ID="$(jq -r .data.aws_access_key_id aws-creds.json | base64 -d)"
  AWS_SECRET_ACCESS_KEY="$(jq -r .data.aws_secret_access_key aws-creds.json | base64 -d)"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  
  # Get AWS region and infrastructure details from cluster
  # Note: no 'local' on exported vars — local variables die on function return
  local INSTANCE_ID
  INSTANCE_ID=$(oc get nodes -l 'node-role.kubernetes.io/worker' -o jsonpath='{.items[0].spec.providerID}' | sed 's#[^ ]*/##g')
  
  AWS_REGION=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.aws.region}')
  
  # Query AWS for networking details
  AWS_SUBNET_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[*].Instances[*].SubnetId' --region "${AWS_REGION}" --output text)
  AWS_VPC_ID=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[*].Instances[*].VpcId' --region "${AWS_REGION}" --output text)
  AWS_SG_IDS=$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --query 'Reservations[*].Instances[*].SecurityGroups[*].GroupId' --region "${AWS_REGION}" --output text | tr ' \t' ',')
  
  # Open security group ports for peer-pods VXLAN and CAA
  for AWS_SG_ID in ${AWS_SG_IDS/,/ }; do
    aws ec2 authorize-security-group-ingress \
        --group-id "${AWS_SG_ID}" --protocol tcp --port 15150 \
        --source-group "${AWS_SG_ID}" --region "${AWS_REGION}" \
        --no-paginate 2>/dev/null || true
    aws ec2 authorize-security-group-ingress \
        --group-id "${AWS_SG_ID}" --protocol tcp --port 9000 \
        --source-group "${AWS_SG_ID}" --region "${AWS_REGION}" \
        --no-paginate 2>/dev/null || true
  done
  
  # Export environment variables (only if not already set)
  export AWS_REGION AWS_SUBNET_ID AWS_VPC_ID AWS_SG_IDS
  : "${VXLAN_PORT:=9000}"
  : "${PODVM_INSTANCE_TYPE:=t3.medium}"
  : "${PROXY_TIMEOUT:=30m}"
  
  echo ">>> AWS peer-pods config detected: region=${AWS_REGION}, subnet=${AWS_SUBNET_ID}, vpc=${AWS_VPC_ID}" >&2
}

function setup_azure_peerpods() {
  echo ">>> Detecting Azure peer-pods configuration from cluster" >&2

  # Get resource group from cluster infrastructure
  # Note: no 'local' on exported vars — local variables die on function return
  AZURE_RESOURCE_GROUP=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.azure.resourceGroupName}')
  if [[ -z "${AZURE_RESOURCE_GROUP}" ]]; then
    echo ">>> ERROR: Could not determine Azure resource group from cluster infrastructure" >&2
    return 1
  fi

  # Login to Azure using credentials from the cluster secret
  local azure_client_id azure_client_secret azure_tenant_id azure_subscription_id
  local azure_creds
  azure_creds=$(oc -n kube-system get secret azure-credentials -o json 2>/dev/null)
  if [[ -z "${azure_creds}" ]] && [[ -n "${CLUSTER_PROFILE_DIR:-}" ]]; then
    local sp="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
    azure_client_id=$(jq -r .clientId "${sp}")
    azure_client_secret=$(jq -r .clientSecret "${sp}")
    azure_tenant_id=$(jq -r .tenantId "${sp}")
    azure_subscription_id=$(jq -r .subscriptionId "${sp}")
  else
    azure_client_id=$(echo "${azure_creds}" | jq -r .data.azure_client_id | base64 -d)
    azure_client_secret=$(echo "${azure_creds}" | jq -r .data.azure_client_secret | base64 -d)
    azure_tenant_id=$(echo "${azure_creds}" | jq -r .data.azure_tenant_id | base64 -d)
    azure_subscription_id=$(echo "${azure_creds}" | jq -r .data.azure_subscription_id | base64 -d)
  fi

  # Temporarily disable tracing to avoid leaking credentials
  [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
  set +x
  az login --service-principal \
    --username "${azure_client_id}" \
    --password "${azure_client_secret}" \
    --tenant "${azure_tenant_id}" --output none
  az account set --subscription "${azure_subscription_id}"
  $WAS_TRACING && set -x || true

  # Get region from the resource group (not cloudName which is e.g. "AzurePublicCloud")
  AZURE_REGION=$(az group show --resource-group "${AZURE_RESOURCE_GROUP}" \
    --query location --output tsv)

  # Determine management resource group (differs for ARO)
  local mgmt_rg
  if oc get crd clusters.aro.openshift.io &>/dev/null; then
    mgmt_rg="$(cat "${SHARED_DIR}/resourcegroup" 2>/dev/null || echo "${AZURE_RESOURCE_GROUP}")"
  else
    mgmt_rg="${AZURE_RESOURCE_GROUP}"
  fi

  # Get VNet (retry up to 30s)
  local azure_vnet_name
  for i in {1..10}; do
    azure_vnet_name=$(az network vnet list --resource-group "${mgmt_rg}" \
      --query '[].name' --output tsv 2>/dev/null | head -1)
    [[ -n "${azure_vnet_name}" ]] && break
    sleep 3
  done
  if [[ -z "${azure_vnet_name}" ]]; then
    echo ">>> ERROR: Could not find Azure VNet in resource group ${mgmt_rg}" >&2
    return 1
  fi

  # Get worker subnet ID and NSG ID
  AZURE_SUBNET_ID=$(az network vnet subnet list \
    --resource-group "${mgmt_rg}" --vnet-name "${azure_vnet_name}" \
    --query "[?contains(name,'worker')].id | [0]" --output tsv 2>/dev/null)
  AZURE_NSG_ID=$(az network nsg list \
    --resource-group "${AZURE_RESOURCE_GROUP}" \
    --query '[].id | [0]' --output tsv 2>/dev/null)

  # Apply defaults for values not already set
  : "${AZURE_INSTANCE_SIZE:=Standard_B2als_v2}"
  : "${VXLAN_PORT:=9000}"
  : "${PROXY_TIMEOUT:=30m}"

  # Export so the helm --set-string block picks them up
  export AZURE_RESOURCE_GROUP AZURE_REGION AZURE_SUBNET_ID AZURE_NSG_ID

  echo ">>> Azure peer-pods config detected:" >&2
  echo ">>>   AZURE_RESOURCE_GROUP=${AZURE_RESOURCE_GROUP}" >&2
  echo ">>>   AZURE_REGION=${AZURE_REGION}" >&2
  echo ">>>   AZURE_SUBNET_ID=${AZURE_SUBNET_ID}" >&2
  echo ">>>   AZURE_NSG_ID=${AZURE_NSG_ID}" >&2
  echo ">>>   AZURE_INSTANCE_SIZE=${AZURE_INSTANCE_SIZE}" >&2
  echo ">>>   (AZURE_IMAGE_ID must be set via env var in job config)" >&2
}

function setup_gcp_peerpods() {
  echo ">>> Detecting GCP peer-pods configuration from cluster" >&2
  
  # Note: no 'local' on exported vars — local variables die on function return
  # Get GCP project and network details from cluster
  GCP_PROJECT_ID=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.gcp.projectID}')
  GCP_ZONE=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.gcp.region}')
  GCP_NETWORK=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.gcp.network}')
  
  if [[ -z "${GCP_PROJECT_ID}" ]] || [[ -z "${GCP_ZONE}" ]]; then
    echo ">>> WARNING: Could not determine GCP project or zone" >&2
    return 1
  fi
  
  # Default machine type if not specified
  : "${GCP_MACHINE_TYPE:=e2-standard-4}"
  : "${VXLAN_PORT:=9000}"
  : "${PROXY_TIMEOUT:=30m}"
  
  # Export environment variables (only if not already set)
  export GCP_PROJECT_ID GCP_ZONE GCP_NETWORK
  
  echo ">>> GCP peer-pods config detected: project=${GCP_PROJECT_ID}, zone=${GCP_ZONE}, network=${GCP_NETWORK}" >&2
}

function render_osc_operator_chart() {
  local charts_dir="$1"
  local operator_chart="${charts_dir}/osc-operator"

  if [[ ! -d "${operator_chart}" ]]; then
    echo ">>> ERROR: Operator chart not found at ${operator_chart}" >&2
    return 1
  fi

  echo ">>> Rendering osc-operator chart from: ${operator_chart}" >&2

  local helm_args=(
    "osc-operator"
    "${operator_chart}"
    "--namespace" "${OSC_NAMESPACE}"
    "--set" "namespaceOverride=${OSC_NAMESPACE}"
  )

  if [[ -n "${CATALOG_SOURCE_IMAGE}" ]]; then
    helm_args+=("--set" "dev.enabled=true" "--set" "dev.image=${CATALOG_SOURCE_IMAGE}")
    echo ">>> Helm: dev.enabled=true, dev.image=${CATALOG_SOURCE_IMAGE}" >&2
  else
    helm_args+=("--set" "dev.enabled=false")
  fi

  local helm_output
  if ! helm_output=$(helm template "${helm_args[@]}"); then
    echo ">>> ERROR: helm template failed" >&2
    return 1
  fi

  echo "$helm_output"
}

function render_osc_operands_chart() {
  local charts_dir="$1"
  local operands_chart="${charts_dir}/osc-operands"

  if [[ ! -d "${operands_chart}" ]]; then
    echo ">>> ERROR: Operands chart not found at ${operands_chart}" >&2
    return 1
  fi

  echo ">>> Rendering osc-operands chart from: ${operands_chart}" >&2

  local helm_args=(
    "osc-operands"
    "${operands_chart}"
    "--namespace" "${OSC_NAMESPACE}"
    "--set" "namespaceOverride=${OSC_NAMESPACE}"
  )

  # openshift-tests-private expects kataconfig named "example-kataconfig"
  helm_args+=("--set" "kataconfig.name=example-kataconfig")

  # Workload-specific settings
  if [[ "${WORKLOAD_TO_TEST}" == "coco" ]]; then
    helm_args+=("--set" "confidential.enabled=true")
    echo ">>> Helm: confidential.enabled=true" >&2
  else
    helm_args+=("--set" "confidential.enabled=false")
  fi

  if [[ "${ENABLEPEERPODS}" == "true" ]]; then
    helm_args+=("--set" "peerpods.enabled=true")

    local provider
    provider=$(get_cloud_provider)
    helm_args+=("--set" "peerpods.provider=${provider}")
    echo ">>> Helm: peerpods.enabled=true, provider=${provider}" >&2

    # Generate SSH keys via the chart's Makefile (ed25519, into files/ for .Files.Get)
    make -C "${operands_chart}" ssh-keys >&2

    # Detect and populate cloud configuration from cluster infrastructure
    # Cloud setup functions export environment variables if not already set
    case "${provider}" in
      aws)
        setup_aws_peerpods || echo ">>> WARNING: Failed to detect AWS peer-pods config" >&2
        ;;
      azure)
        setup_azure_peerpods || echo ">>> WARNING: Failed to detect Azure peer-pods config" >&2
        ;;
      gcp)
        setup_gcp_peerpods || echo ">>> WARNING: Failed to detect GCP peer-pods config" >&2
        ;;
      libvirt|none)
        echo ">>> Skipping peer-pods cloud config for libvirt (local testing)" >&2
        ;;
      *)
        echo ">>> WARNING: Unsupported provider for peer-pods: ${provider}" >&2
        ;;
    esac

    # Read cloud config from environment variables
    # Variables can come from job config, step defaults, or cloud setup functions above
    # Helm charts will create peer-pods-cm ConfigMap with these values
    echo ">>> Reading peer-pods cloud config from environment variables" >&2

      # Extract common values
      local vxlan_port proxy_timeout podvm_image_uri tags peerpods_limit
      vxlan_port="${VXLAN_PORT:-}"
      proxy_timeout="${PROXY_TIMEOUT:-}"
      podvm_image_uri="${PODVM_IMAGE_URI:-}"
      tags="${TAGS:-}"
      peerpods_limit="${PEERPODS_LIMIT_PER_NODE:-10}"
      [[ -n "${vxlan_port}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.all.VXLAN_PORT=${vxlan_port}")
      [[ -n "${proxy_timeout}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.all.PROXY_TIMEOUT=${proxy_timeout}")
      # Override helm's GCP-specific default PODVM_IMAGE_URI to empty for non-GCP providers
      helm_args+=("--set-string" "peerpods.providersConfigs.all.PODVM_IMAGE_URI=${podvm_image_uri}")
      [[ -n "${tags}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.all.TAGS=${tags}")
      helm_args+=("--set-string" "peerpods.providersConfigs.all.PEERPODS_LIMIT_PER_NODE=${peerpods_limit}")

      case "${provider}" in
        azure)
          local azure_image_id azure_subnet_id azure_nsg_id azure_resource_group azure_region azure_instance_size azure_instance_sizes azure_ssh_key_pub
          azure_image_id="${AZURE_IMAGE_ID:-}"
          azure_subnet_id="${AZURE_SUBNET_ID:-}"
          azure_nsg_id="${AZURE_NSG_ID:-}"
          azure_resource_group="${AZURE_RESOURCE_GROUP:-}"
          azure_region="${AZURE_REGION:-}"
          azure_instance_size="${AZURE_INSTANCE_SIZE:-}"
          azure_instance_sizes="${AZURE_INSTANCE_SIZES:-Standard_B2als_v2,Standard_B2as_v2,Standard_D2as_v5,Standard_B4als_v2,Standard_D4as_v5,Standard_D8as_v5}"
          # SSH public key: use env var if set, else read from key file generated by make ssh-keys
          azure_ssh_key_pub="${AZURE_SSH_KEY_PUB:-}"
          if [[ -z "${azure_ssh_key_pub}" && -f "${operands_chart}/files/id_rsa.pub" ]]; then
            azure_ssh_key_pub=$(base64 -w 0 < "${operands_chart}/files/id_rsa.pub")
          fi
          [[ -n "${azure_image_id}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.azure.AZURE_IMAGE_ID=${azure_image_id}")
          [[ -n "${azure_subnet_id}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.azure.AZURE_SUBNET_ID=${azure_subnet_id}")
          [[ -n "${azure_nsg_id}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.azure.AZURE_NSG_ID=${azure_nsg_id}")
          [[ -n "${azure_resource_group}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.azure.AZURE_RESOURCE_GROUP=${azure_resource_group}")
          [[ -n "${azure_region}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.azure.AZURE_REGION=${azure_region}")
          [[ -n "${azure_instance_size}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.azure.AZURE_INSTANCE_SIZE=${azure_instance_size}") || true
          [[ -n "${azure_instance_sizes}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.azure.AZURE_INSTANCE_SIZES=${azure_instance_sizes//,/\\,}")
          [[ -n "${azure_ssh_key_pub}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.azure.AZURE_SSH_KEY_PUB=${azure_ssh_key_pub}") || true
          ;;
        aws)
          local aws_region aws_subnet_id aws_vpc_id aws_sg_ids podvm_instance_type podvm_ami_id podvm_instance_types
          aws_region="${AWS_REGION:-}"
          aws_subnet_id="${AWS_SUBNET_ID:-}"
          aws_vpc_id="${AWS_VPC_ID:-}"
          aws_sg_ids="${AWS_SG_IDS:-}"
          podvm_instance_type="${PODVM_INSTANCE_TYPE:-t3.medium}"
          podvm_ami_id="${PODVM_AMI_ID:-}"
          podvm_instance_types="${PODVM_INSTANCE_TYPES:-t3.small,t3.medium,t3.large,t3.xlarge,t3.2xlarge,g4dn.2xlarge,g5.2xlarge,p3.2xlarge}"
          [[ -n "${aws_region}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.aws.AWS_REGION=${aws_region}")
          [[ -n "${aws_subnet_id}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.aws.AWS_SUBNET_ID=${aws_subnet_id}")
          [[ -n "${aws_vpc_id}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.aws.AWS_VPC_ID=${aws_vpc_id}")
          [[ -n "${aws_sg_ids}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.aws.AWS_SG_IDS=${aws_sg_ids//,/\\,}")
          [[ -n "${podvm_instance_type}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.aws.PODVM_INSTANCE_TYPE=${podvm_instance_type}")
          [[ -n "${podvm_ami_id}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.aws.PODVM_AMI_ID=${podvm_ami_id}")
          [[ -n "${podvm_instance_types}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.aws.PODVM_INSTANCE_TYPES=${podvm_instance_types//,/\\,}")
          ;;
        gcp)
          local gcp_project_id gcp_zone gcp_network gcp_machine_type
          gcp_project_id="${GCP_PROJECT_ID:-}"
          gcp_zone="${GCP_ZONE:-}"
          gcp_network="${GCP_NETWORK:-}"
          gcp_machine_type="${GCP_MACHINE_TYPE:-}"
          [[ -n "${gcp_project_id}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.gcp.GCP_PROJECT_ID=${gcp_project_id}")
          [[ -n "${gcp_zone}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.gcp.GCP_ZONE=${gcp_zone}")
          [[ -n "${gcp_network}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.gcp.GCP_NETWORK=${gcp_network}")
          [[ -n "${gcp_machine_type}" ]] && helm_args+=("--set-string" "peerpods.providersConfigs.gcp.GCP_MACHINE_TYPE=${gcp_machine_type}") || true
          ;;
      esac
  else
    helm_args+=("--set" "peerpods.enabled=false")
  fi

  local helm_output
  if ! helm_output=$(helm template "${helm_args[@]}"); then
    echo ">>> ERROR: helm template failed" >&2
    return 1
  fi

  echo "$helm_output"
}

function install_osc_operator() {
  local charts_dir="$1"

  echo ">>> Installing OSC operator"

  echo ">>> Creating namespace ${OSC_NAMESPACE}"
  oc create namespace "${OSC_NAMESPACE}" 2>/dev/null || true

  local operator_yaml="${SCRATCH}/operator-manifests.yaml"
  if ! render_osc_operator_chart "${charts_dir}" > "${operator_yaml}"; then
    echo ">>> ERROR: Failed to render operator chart"
    return 1
  fi

  echo ">>> Rendered operator objects:"
  oc apply -f "${operator_yaml}" --dry-run=client -o name || true

  oc_with_retry oc apply -f "${operator_yaml}"
}

function wait_for_operator() {
  # Workaround: helm chart creates osc-operator-dev-catalog even when dev.enabled=false (chart bug).
  # Delete it now if we're not using a custom catalog so Stage 0 doesn't wait for a broken source.
  if [[ -z "${CATALOG_SOURCE_IMAGE}" ]]; then
    if oc get catalogsource -n openshift-marketplace "${OSC_DEV_CATALOG_NAME}" &>/dev/null; then
      echo ">>> Deleting stale ${OSC_DEV_CATALOG_NAME} (no CATALOG_SOURCE_IMAGE set, chart bug workaround)"
      oc delete catalogsource -n openshift-marketplace "${OSC_DEV_CATALOG_NAME}" --ignore-not-found
    fi
  fi

  # Stage 0: Wait for ALL CatalogSources to be READY (600s)
  echo ">>> Waiting for all CatalogSources to be READY..."
  local all_catalogs_ready=false
  for i in {1..120}; do
    local catalog_states
    catalog_states=$(oc get catalogsource -n openshift-marketplace -o jsonpath='{range .items[*]}{.metadata.name}={.status.connectionState.lastObservedState}{"\n"}{end}' 2>/dev/null || echo "")

    if [[ -z "${catalog_states}" ]]; then
      [[ ${i} -lt 120 ]] && sleep 5
      continue
    fi

    local total_catalogs ready_catalogs
    total_catalogs=$(echo "${catalog_states}" | wc -l)
    ready_catalogs=$(echo "${catalog_states}" | grep -c "=READY" || true)
    ready_catalogs=${ready_catalogs:-0}

    if [[ ${ready_catalogs} -eq ${total_catalogs} && ${ready_catalogs} -gt 0 ]]; then
      echo ">>> All CatalogSources are READY (${ready_catalogs}/${total_catalogs})"
      all_catalogs_ready=true
      break
    fi

    if [[ $((i % 6)) -eq 0 ]]; then
      echo ">>> CatalogSources ready: ${ready_catalogs}/${total_catalogs} ($((i*5))s elapsed)..."
    fi

    [[ ${i} -lt 120 ]] && sleep 5
  done

  if [[ "${all_catalogs_ready}" != "true" ]]; then
    echo ">>> ERROR: Not all CatalogSources are READY after 600s"
    oc get catalogsource -n openshift-marketplace -o custom-columns=NAME:.metadata.name,STATE:.status.connectionState.lastObservedState || true
    return 1
  fi

  # Stage 1: Wait for the dev CatalogSource created by the helm chart
  if [[ -n "${CATALOG_SOURCE_IMAGE}" ]]; then
    if ! wait_until "CatalogSource ${OSC_DEV_CATALOG_NAME} READY" 300 5 \
      "[[ \"\$(oc get catalogsource -n openshift-marketplace '${OSC_DEV_CATALOG_NAME}' -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null)\" == \"READY\" ]]"; then
      oc get catalogsource -n openshift-marketplace || true
      oc describe catalogsource -n openshift-marketplace "${OSC_DEV_CATALOG_NAME}" || true
      return 1
    fi
  fi

  # Stage 2: Wait for Subscription to reference an InstallPlan (300s)
  if ! wait_until "Subscription to reference InstallPlan" 300 5 \
    "oc get subscription -n '${OSC_NAMESPACE}' sandboxed-containers-operator -o jsonpath='{.status.installplan.name}' 2>/dev/null | grep -q '^install-'"; then
    echo ">>> ERROR: Subscription has no InstallPlan reference" >&2
    oc get subscription -n "${OSC_NAMESPACE}" sandboxed-containers-operator -o yaml || true
    return 1
  fi

  local installplan_ref
  installplan_ref=$(oc get subscription -n "${OSC_NAMESPACE}" sandboxed-containers-operator -o jsonpath='{.status.installplan.name}' 2>/dev/null || echo "")
  echo ">>> InstallPlan: ${installplan_ref}"

  # Stage 3: Wait for InstallPlan to be Complete (300s)
  if ! wait_until "InstallPlan ${installplan_ref} Complete" 300 5 \
    "[[ \"\$(oc get installplan -n '${OSC_NAMESPACE}' '${installplan_ref}' -o jsonpath='{.status.phase}' 2>/dev/null)\" == \"Complete\" ]]"; then
    oc get installplan -n "${OSC_NAMESPACE}" "${installplan_ref}" -o yaml || true
    return 1
  fi

  # Stage 4: Wait for CSV to be Succeeded (600s)
  if ! wait_until "CSV Succeeded" 600 5 \
    "[[ \"\$(oc get csv -n '${OSC_NAMESPACE}' -o jsonpath='{.items[0].status.phase}' 2>/dev/null)\" == \"Succeeded\" ]]"; then
    oc get csv -n "${OSC_NAMESPACE}" -o yaml || true
    return 1
  fi

  local csv_name
  csv_name=$(oc get csv -n "${OSC_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  echo ">>> CSV ${csv_name} is Succeeded"

  # Stage 5: Wait for controller-manager Deployment to be Available (900s)
  if ! wait_until "controller-manager deployment Available" 900 5 \
    "oc get deployment -n '${OSC_NAMESPACE}' controller-manager -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>/dev/null | grep -q 'True'"; then
    oc get deployment -n "${OSC_NAMESPACE}" || true
    oc get pods -n "${OSC_NAMESPACE}" || true
    return 1
  fi

  # Stage 6: Wait for controller-manager rollout to complete (900s)
  if ! wait_until "controller-manager rollout complete" 900 5 \
    "oc rollout status deployment/controller-manager -n '${OSC_NAMESPACE}' --timeout=0 2>/dev/null | grep -q 'successfully rolled out'"; then
    oc get pods -n "${OSC_NAMESPACE}" || true
    oc describe deployment -n "${OSC_NAMESPACE}" controller-manager | tail -30 || true
    return 1
  fi

  oc get pods -n "${OSC_NAMESPACE}" || true
  echo ">>> OSC operator installation complete"
}

function install_osc_operands() {
  local charts_dir="$1"

  echo ">>> Installing OSC operands (workload: ${WORKLOAD_TO_TEST}, peerpods: ${ENABLEPEERPODS})"

  local operands_yaml="${SCRATCH}/operands-manifests.yaml"
  if ! render_osc_operands_chart "${charts_dir}" > "${operands_yaml}"; then
    echo ">>> ERROR: Failed to render operands chart"
    return 1
  fi

  echo ">>> Rendered operands objects:"
  oc apply -f "${operands_yaml}" --dry-run=client -o name || true

  oc_with_retry oc apply -f "${operands_yaml}"
}

function create_peer_pods_secret() {
  echo ">>> Creating peer-pods-secret in ${OSC_NAMESPACE}"

  # Check if secret already exists
  if oc get secret peer-pods-secret -n "${OSC_NAMESPACE}" &>/dev/null; then
    echo ">>> peer-pods-secret already exists, skipping"
    return 0
  fi

  # Detect identity mode from osc-config or default to manual
  local identity_mode
  identity_mode=$(oc get configmap osc-config -n default -o jsonpath='{.data.identityMode}' 2>/dev/null || echo "manual")

  case "${identity_mode}" in
    cco)
      echo ">>> Identity mode: cco (Cloud Credential Operator handles credentials)"
      return 0
      ;;
    sts)
      echo ">>> Identity mode: sts (credentials via subscription environment)"
      return 0
      ;;
    manual|*)
      echo ">>> Identity mode: manual (copying credentials from peerpods-param-secret)"
      ;;
  esac

  # Read peerpods-param-secret from default namespace
  if ! oc get secret peerpods-param-secret -n default &>/dev/null; then
    echo ">>> WARNING: peerpods-param-secret not found in default namespace"
    return 0
  fi

  local provider
  provider=$(get_cloud_provider)

  case "${provider}" in
    azure)
      # Extract Azure service principal credentials
      local sp_json
      sp_json=$(oc get secret peerpods-param-secret -n default -o jsonpath='{.data.osServicePrincipal\.json}' 2>/dev/null || echo "")
      if [[ -z "${sp_json}" ]]; then
        # Try auth.json format
        sp_json=$(oc get secret peerpods-param-secret -n default -o jsonpath='{.data.auth\.json}' 2>/dev/null || echo "")
      fi

      if [[ -n "${sp_json}" ]]; then
        local decoded
        decoded=$(echo "${sp_json}" | base64 -d)
        local client_id client_secret tenant_id
        client_id=$(echo "${decoded}" | jq -r '.clientId // .azure.azure_client_id // ""')
        client_secret=$(echo "${decoded}" | jq -r '.clientSecret // .azure.azure_client_secret // ""')
        tenant_id=$(echo "${decoded}" | jq -r '.tenantId // .azure.azure_tenant_id // ""')

        local subscription_id
        subscription_id=$(oc get secret azure-credentials -n kube-system -o jsonpath='{.data.azure_subscription_id}' 2>/dev/null | base64 -d || echo "")

        set +x
        oc_with_retry oc create secret generic peer-pods-secret \
          -n "${OSC_NAMESPACE}" \
          --from-literal="AZURE_CLIENT_ID=${client_id}" \
          --from-literal="AZURE_CLIENT_SECRET=${client_secret}" \
          --from-literal="AZURE_TENANT_ID=${tenant_id}" \
          --from-literal="AZURE_SUBSCRIPTION_ID=${subscription_id}"
      else
        echo ">>> WARNING: Could not extract Azure credentials from peerpods-param-secret"
      fi
      ;;
    aws)
      # Extract AWS credentials
      local auth_json
      auth_json=$(oc get secret peerpods-param-secret -n default -o jsonpath='{.data.auth\.json}' 2>/dev/null || echo "")
      if [[ -n "${auth_json}" ]]; then
        echo "${auth_json}" | base64 -d > "${SCRATCH}/auth.json"
        oc_with_retry oc create secret generic peer-pods-secret \
          -n "${OSC_NAMESPACE}" \
          --from-file="${SCRATCH}/auth.json"
        rm -f "${SCRATCH}/auth.json"
      else
        echo ">>> WARNING: Could not extract AWS credentials from peerpods-param-secret"
      fi
      ;;
    *)
      echo ">>> WARNING: peer-pods-secret creation not implemented for provider: ${provider}"
      ;;
  esac
}

function wait_for_kataconfig() {
  echo ">>> Waiting for KataConfig to be ready (this may take up to 2 hours for node reboots)"

  # Wait for KataConfig CR to exist
  if ! wait_until "KataConfig CR to exist" 60 5 \
    "oc get kataconfig -o name 2>/dev/null | grep -q 'kataconfig'"; then
    echo ">>> ERROR: KataConfig not found"
    return 1
  fi

  local kataconfig_name
  kataconfig_name=$(oc get kataconfig -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  echo ">>> KataConfig name: ${kataconfig_name}"

  # Wait for KataConfig InProgress condition to be False (7200s / 2h)
  if ! wait_until "KataConfig ready (InProgress=False)" 7200 30 \
    "[[ \"\$(oc get kataconfig '${kataconfig_name}' -o jsonpath='{.status.conditions[?(@.type==\"InProgress\")].status}' 2>/dev/null)\" == \"False\" ]]"; then
    echo ">>> ERROR: KataConfig not ready after 2 hours"
    oc get kataconfig "${kataconfig_name}" -o yaml || true
    oc get nodes || true
    oc get mcp || true
    return 1
  fi

  # Check for Failed condition
  local failed_status
  failed_status=$(oc get kataconfig "${kataconfig_name}" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null || echo "")
  if [[ "${failed_status}" == "True" ]]; then
    echo ">>> ERROR: KataConfig has Failed condition"
    oc get kataconfig "${kataconfig_name}" -o yaml || true
    oc get nodes || true
    oc get mcp || true
    return 1
  fi

  # Verify at least one node is ready
  local ready_nodes
  ready_nodes=$(oc get kataconfig "${kataconfig_name}" -o jsonpath='{.status.kataNodes.readyNodeCount}' 2>/dev/null || echo "0")
  if [[ "${ready_nodes}" -lt 1 ]]; then
    echo ">>> ERROR: KataConfig has no ready nodes (readyNodeCount=${ready_nodes})"
    oc get kataconfig "${kataconfig_name}" -o yaml || true
    oc get nodes || true
    return 1
  fi

  echo ">>> KataConfig is ready (readyNodeCount=${ready_nodes})"
  oc get kataconfig "${kataconfig_name}" -o jsonpath='{.status}' 2>/dev/null | jq . || true
}

#========================================
# Update Shared State
#========================================

function update_osc_config() {
  echo ">>> Patching osc-config ConfigMap to indicate operator is installed"

  if ! oc get configmap osc-config -n default &>/dev/null; then
    echo ">>> WARNING: osc-config ConfigMap not found in default namespace"
    return 0
  fi

  oc_with_retry oc patch configmap osc-config -n default --type merge \
    -p '{"data":{"oscInstalled":"true"}}'

  echo ">>> osc-config patched with oscInstalled=true"
}

#========================================
# Main Execution
#========================================

echo "========================================="
echo ">>> OSC Operator Installation"
echo ">>> Workload: ${WORKLOAD_TO_TEST}"
echo ">>> Peer-pods: ${ENABLEPEERPODS}"
echo "========================================="

# Phase 1: Set up CatalogSource (if Pre-GA)
setup_catalog_source

# Phase 2: Fetch charts
CHARTS_DIR=$(fetch_osc_charts)
echo ">>> Charts directory: ${CHARTS_DIR}"

# Phase 3: Install operator
install_osc_operator "${CHARTS_DIR}"
wait_for_operator

# Phase 4: Install operands
if [[ "${ENABLEPEERPODS}" == "true" ]]; then
  create_peer_pods_secret
fi

install_osc_operands "${CHARTS_DIR}"
wait_for_kataconfig

# Phase 5: Update shared state
update_osc_config

echo "========================================="
echo ">>> OSC operator installation complete"
echo ">>> Workload: ${WORKLOAD_TO_TEST}"
echo ">>> Namespace: ${OSC_NAMESPACE}"
echo "========================================="
