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
# Pick up the resolved catalog image from env-cm step (resolves :latest to a specific tag)
if [[ -f "${SHARED_DIR}/catalog-source-image.env" ]]; then
  # shellcheck disable=SC1091
  source "${SHARED_DIR}/catalog-source-image.env"
fi
OSC_CHARTS_REPO=${OSC_CHARTS_REPO:-https://github.com/confidential-devhub/charts.git}
OSC_CHARTS_REF=${OSC_CHARTS_REF:-main}
ENABLEPEERPODS=${ENABLEPEERPODS:-false}
WORKLOAD_TO_TEST=${WORKLOAD_TO_TEST:-kata}

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
  echo ">>> Catalog source: osc-operator-dev-catalog (image: ${CATALOG_SOURCE_IMAGE})"
else
  echo ">>> Catalog source: redhat-operators (using existing catalog)"
fi

#========================================
# Cleanup Handler
#========================================

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
    oc logs -n "${OSC_NAMESPACE}" -l name=controller-manager --tail=50 || true
  fi
}
trap 'exit_handler' EXIT

#========================================
# Helper Functions
#========================================

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

#========================================
# Chart Fetching
#========================================

function fetch_osc_charts() {
  local charts_dir="${SCRATCH}/charts"

  echo ">>> Fetching OSC charts from: ${OSC_CHARTS_REPO} (ref: ${OSC_CHARTS_REF})" >&2

  mkdir -p "${charts_dir}"
  rm -rf "${charts_dir}"
  git clone --depth 1 --branch "${OSC_CHARTS_REF}" "${OSC_CHARTS_REPO}" "${charts_dir}"

  if [[ ! -d "${charts_dir}" ]]; then
    echo ">>> ERROR: Failed to clone charts repository" >&2
    exit 1
  fi

  echo ">>> Charts fetched" >&2
  local result_dir
  if [[ -d "${charts_dir}/charts" ]]; then
    result_dir="${charts_dir}/charts"
  else
    result_dir="${charts_dir}"
  fi

  # DEBUG until https://github.com/confidential-devhub/charts/pull/3 merges
  if grep -q 'startingCSV' "${result_dir}/osc-operator/templates/subscription.yaml" 2>/dev/null; then
    sed -i '/startingCSV/d' "${result_dir}/osc-operator/templates/subscription.yaml"
    echo ">>> DEBUG: subscription.yaml patched (removed startingCSV line). PR 3 not merged yet." >&2
  fi

  echo "${result_dir}"
}

#========================================
# Cloud Provider Detection
#========================================

function get_cloud_provider() {
  local provider
  provider=$(oc get infrastructure/cluster -o jsonpath='{.status.platformStatus.type}' 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if [[ "${provider}" == "none" ]]; then
    provider="libvirt"
  fi
  echo "${provider}"
}

#========================================
# Helm Chart Rendering
#========================================

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
    helm_args+=(
      "--set" "dev.enabled=true"
      "--set" "dev.image=${CATALOG_SOURCE_IMAGE}"
    )
    echo ">>> Helm: dev.enabled=true, dev.image=${CATALOG_SOURCE_IMAGE}" >&2
  else
    helm_args+=(
      "--set" "dev.enabled=false"
    )
    echo ">>> Helm: dev.enabled=false (using redhat-operators)" >&2
  fi

  local helm_output
  if ! helm_output=$(helm template "${helm_args[@]}" 2>&1); then
    echo ">>> ERROR: helm template failed" >&2
    echo "$helm_output" >&2
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

    # Read cloud config from peerpods-param-cm (created by peerpods-param-cm step)
    local cm_data
    cm_data=$(oc get configmap peerpods-param-cm -n default -o json 2>/dev/null || echo "")
    if [[ -n "${cm_data}" ]]; then
      echo ">>> Reading cloud config from peerpods-param-cm" >&2

      # Extract common values
      local vxlan_port proxy_timeout
      vxlan_port=$(echo "${cm_data}" | jq -r '.data.VXLAN_PORT // ""')
      proxy_timeout=$(echo "${cm_data}" | jq -r '.data.PROXY_TIMEOUT // ""')
      [[ -n "${vxlan_port}" ]] && helm_args+=("--set" "peerpods.providersConfigs.all.VXLAN_PORT=${vxlan_port}")
      [[ -n "${proxy_timeout}" ]] && helm_args+=("--set" "peerpods.providersConfigs.all.PROXY_TIMEOUT=${proxy_timeout}")

      case "${provider}" in
        azure)
          local azure_subnet_id azure_nsg_id azure_resource_group azure_region azure_instance_size
          azure_subnet_id=$(echo "${cm_data}" | jq -r '.data.AZURE_SUBNET_ID // ""')
          azure_nsg_id=$(echo "${cm_data}" | jq -r '.data.AZURE_NSG_ID // ""')
          azure_resource_group=$(echo "${cm_data}" | jq -r '.data.AZURE_RESOURCE_GROUP // ""')
          azure_region=$(echo "${cm_data}" | jq -r '.data.AZURE_REGION // ""')
          azure_instance_size=$(echo "${cm_data}" | jq -r '.data.AZURE_INSTANCE_SIZE // ""')
          [[ -n "${azure_subnet_id}" ]] && helm_args+=("--set" "peerpods.providersConfigs.azure.AZURE_SUBNET_ID=${azure_subnet_id}")
          [[ -n "${azure_nsg_id}" ]] && helm_args+=("--set" "peerpods.providersConfigs.azure.AZURE_NSG_ID=${azure_nsg_id}")
          [[ -n "${azure_resource_group}" ]] && helm_args+=("--set" "peerpods.providersConfigs.azure.AZURE_RESOURCE_GROUP=${azure_resource_group}")
          [[ -n "${azure_region}" ]] && helm_args+=("--set" "peerpods.providersConfigs.azure.AZURE_REGION=${azure_region}")
          # Let chart auto-set AZURE_INSTANCE_SIZE based on confidential mode if not explicitly set
          [[ -n "${azure_instance_size}" ]] && helm_args+=("--set" "peerpods.providersConfigs.azure.AZURE_INSTANCE_SIZE=${azure_instance_size}")
          ;;
        aws)
          local aws_region aws_subnet_id aws_vpc_id aws_sg_ids podvm_instance_type
          aws_region=$(echo "${cm_data}" | jq -r '.data.AWS_REGION // ""')
          aws_subnet_id=$(echo "${cm_data}" | jq -r '.data.AWS_SUBNET_ID // ""')
          aws_vpc_id=$(echo "${cm_data}" | jq -r '.data.AWS_VPC_ID // ""')
          aws_sg_ids=$(echo "${cm_data}" | jq -r '.data.AWS_SG_IDS // ""')
          podvm_instance_type=$(echo "${cm_data}" | jq -r '.data.PODVM_INSTANCE_TYPE // ""')
          [[ -n "${aws_region}" ]] && helm_args+=("--set" "peerpods.providersConfigs.aws.AWS_REGION=${aws_region}")
          [[ -n "${aws_subnet_id}" ]] && helm_args+=("--set" "peerpods.providersConfigs.aws.AWS_SUBNET_ID=${aws_subnet_id}")
          [[ -n "${aws_vpc_id}" ]] && helm_args+=("--set" "peerpods.providersConfigs.aws.AWS_VPC_ID=${aws_vpc_id}")
          [[ -n "${aws_sg_ids}" ]] && helm_args+=("--set" "peerpods.providersConfigs.aws.AWS_SG_IDS=${aws_sg_ids}")
          [[ -n "${podvm_instance_type}" ]] && helm_args+=("--set" "peerpods.providersConfigs.aws.PODVM_INSTANCE_TYPE=${podvm_instance_type}")
          ;;
        gcp)
          local gcp_project_id gcp_zone gcp_network gcp_machine_type
          gcp_project_id=$(echo "${cm_data}" | jq -r '.data.GCP_PROJECT_ID // ""')
          gcp_zone=$(echo "${cm_data}" | jq -r '.data.GCP_ZONE // ""')
          gcp_network=$(echo "${cm_data}" | jq -r '.data.GCP_NETWORK // ""')
          gcp_machine_type=$(echo "${cm_data}" | jq -r '.data.GCP_MACHINE_TYPE // ""')
          [[ -n "${gcp_project_id}" ]] && helm_args+=("--set" "peerpods.providersConfigs.gcp.GCP_PROJECT_ID=${gcp_project_id}")
          [[ -n "${gcp_zone}" ]] && helm_args+=("--set" "peerpods.providersConfigs.gcp.GCP_ZONE=${gcp_zone}")
          [[ -n "${gcp_network}" ]] && helm_args+=("--set" "peerpods.providersConfigs.gcp.GCP_NETWORK=${gcp_network}")
          [[ -n "${gcp_machine_type}" ]] && helm_args+=("--set" "peerpods.providersConfigs.gcp.GCP_MACHINE_TYPE=${gcp_machine_type}")
          ;;
      esac
    else
      echo ">>> WARNING: peerpods-param-cm not found in default namespace" >&2
    fi
  else
    helm_args+=("--set" "peerpods.enabled=false")
  fi

  local helm_output
  if ! helm_output=$(helm template "${helm_args[@]}" 2>&1); then
    echo ">>> ERROR: helm template failed" >&2
    echo "$helm_output" >&2
    return 1
  fi

  echo "$helm_output"
}

#========================================
# Installation Functions
#========================================

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

  echo ">>> Rendered operator YAML:"
  cat "${operator_yaml}"

  local apply_output
  if ! apply_output=$(oc apply -f "${operator_yaml}" 2>&1); then
    echo ">>> ERROR: Failed to apply operator manifests"
    echo "$apply_output"
    return 1
  fi

  echo ">>> Apply output:"
  echo "$apply_output"
}

function wait_for_operator() {
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
    ready_catalogs=$(echo "${catalog_states}" | grep -c "=READY" || echo "0")

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

  # Stage 1: Wait for custom CatalogSource if configured
  if [[ -n "${CATALOG_SOURCE_IMAGE}" ]]; then
    if ! wait_until "OSC CatalogSource osc-operator-dev-catalog READY" 60 5 \
      "[[ \"\$(oc get catalogsource -n openshift-marketplace osc-operator-dev-catalog -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null)\" == \"READY\" ]]"; then
      oc get catalogsource -n openshift-marketplace || true
      oc describe catalogsource -n openshift-marketplace osc-operator-dev-catalog || true
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

  # Stage 5: Wait for controller-manager Deployment to be Available (600s)
  if ! wait_until "controller-manager deployment Available" 600 5 \
    "oc get deployment -n '${OSC_NAMESPACE}' controller-manager -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>/dev/null | grep -q 'True'"; then
    oc get deployment -n "${OSC_NAMESPACE}" || true
    oc get pods -n "${OSC_NAMESPACE}" || true
    return 1
  fi

  # Stage 6: Wait for controller-manager pods to be Ready (600s)
  if ! wait_until "controller-manager pods Ready" 600 5 \
    "oc get pods -n '${OSC_NAMESPACE}' -l name=controller-manager -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null | grep -q 'True'"; then
    oc get pods -n "${OSC_NAMESPACE}" || true
    oc describe pods -n "${OSC_NAMESPACE}" -l name=controller-manager | tail -50 || true
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

  echo ">>> Rendered operands YAML:"
  cat "${operands_yaml}"

  local apply_output
  if ! apply_output=$(oc apply -f "${operands_yaml}" 2>&1); then
    echo ">>> ERROR: Failed to apply operands manifests"
    echo "$apply_output"
    return 1
  fi

  echo ">>> Apply output:"
  echo "$apply_output"
}

#========================================
# Peer-Pods Secret Handling
#========================================

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

        cat > "${SCRATCH}/peer-pods-secret.json" <<EOF
{
  "clientId": "${client_id}",
  "clientSecret": "${client_secret}",
  "tenantId": "${tenant_id}",
  "subscriptionId": "${subscription_id}"
}
EOF
        oc create secret generic peer-pods-secret \
          -n "${OSC_NAMESPACE}" \
          --from-file="${SCRATCH}/peer-pods-secret.json"
        rm -f "${SCRATCH}/peer-pods-secret.json"
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
        oc create secret generic peer-pods-secret \
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

#========================================
# KataConfig Wait
#========================================

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

  echo ">>> KataConfig is ready"
  oc get kataconfig "${kataconfig_name}" -o jsonpath='{.status}' 2>/dev/null | jq . || true
}

function verify_peerpod_pods() {
  echo ">>> Verifying peer-pod control pods"

  # Wait for cloud-api-adaptor daemonset pods
  if ! wait_until "cloud-api-adaptor pods running" 600 10 \
    "oc get daemonset -n '${OSC_NAMESPACE}' -l app=cloud-api-adaptor -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null | grep -qE '^[1-9]'"; then
    echo ">>> WARNING: cloud-api-adaptor daemonset not ready"
    oc get daemonset -n "${OSC_NAMESPACE}" || true
    oc get pods -n "${OSC_NAMESPACE}" -l app=cloud-api-adaptor || true
  fi

  # Wait for peerpodconfig-ctrl-caa-daemon
  if ! wait_until "peerpodconfig webhook pod running" 300 10 \
    "oc get pods -n '${OSC_NAMESPACE}' -l app=peerpodconfig-ctrl-caa-daemon -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q 'Running'"; then
    echo ">>> WARNING: peerpodconfig webhook pod not running"
    oc get pods -n "${OSC_NAMESPACE}" || true
  fi

  echo ">>> Peer-pod pods:"
  oc get pods -n "${OSC_NAMESPACE}" || true
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

  oc patch configmap osc-config -n default --type merge \
    -p '{"data":{"oscInstalled":"true"}}' || true

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

if [[ "${ENABLEPEERPODS}" == "true" ]]; then
  verify_peerpod_pods
fi

# Phase 5: Update shared state
update_osc_config

echo "========================================="
echo ">>> OSC operator installation complete"
echo ">>> Workload: ${WORKLOAD_TO_TEST}"
echo ">>> Namespace: ${OSC_NAMESPACE}"
echo "========================================="
