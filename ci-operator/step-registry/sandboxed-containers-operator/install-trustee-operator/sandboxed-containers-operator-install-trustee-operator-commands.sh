#!/usr/bin/env bash
#
# Install Trustee Operator for Confidential Containers (CoCo)
#
# This script installs and configures the Trustee operator and operands using
# helm charts from https://github.com/confidential-devhub/charts
#
# NETWORK ACCESS:
#   Preferred: Use TRUSTEE_CHARTS_IMAGE (pre-built image dependency)
#              Works with restrict_network_access: true for rehearsals
#   Fallback:  Fetches from GitHub (requires restrict_network_access: false)
#
# Environment Variables:
#   TRUSTEE_INSTALL               - "true" to install, "false" to skip (default: false)
#   TRUSTEE_NAMESPACE             - Namespace for operator (default: trustee-operator-system)
#   TRUSTEE_CATALOG_SOURCE_NAME   - CatalogSource name (default: redhat-operators)
#   TRUSTEE_CATALOG_SOURCE_IMAGE  - Custom catalog image (optional)
#   IMAGE_TRUSTEE_CHARTS          - Pre-built charts image (set by ci-operator, recommended)
#   TRUSTEE_CHARTS_REPO           - Charts repo URL (default: https://github.com/confidential-devhub/charts)
#   TRUSTEE_CHARTS_REF            - Charts git ref (default: main)
#   KBS_CLIENT_TAG                - kbs-client version override (optional)
#
# Outputs to SHARED_DIR:
#   TRUSTEE_URL       - KBS service URL for CoCo workloads
#   TRUSTEE_HOST      - KBS hostname
#   TRUSTEE_PORT      - KBS port
#   INITDATA          - Base64-encoded gzipped initdata.toml
#   initdata.toml     - Plain text initdata configuration
#

set -euo pipefail

#========================================
# Configuration
#========================================

export SHARED_DIR=${SHARED_DIR:-/tmp}
export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}

TRUSTEE_INSTALL=${TRUSTEE_INSTALL:-false}
TRUSTEE_NAMESPACE=${TRUSTEE_NAMESPACE:-trustee-operator-system}
TRUSTEE_CATALOG_SOURCE_NAME=${TRUSTEE_CATALOG_SOURCE_NAME:-redhat-operators}
TRUSTEE_CATALOG_SOURCE_IMAGE=${TRUSTEE_CATALOG_SOURCE_IMAGE:-}
TRUSTEE_CHARTS_REPO=${TRUSTEE_CHARTS_REPO:-https://github.com/confidential-devhub/charts}
TRUSTEE_CHARTS_REF=${TRUSTEE_CHARTS_REF:-main}

# Early exit if installation disabled
if [[ "${TRUSTEE_INSTALL}" != "true" ]]; then
  echo ">>> Skipping trustee operator installation (TRUSTEE_INSTALL=${TRUSTEE_INSTALL})"
  exit 0
fi

# Install helm if not available
if ! command -v helm &> /dev/null; then
  echo ">>> Installing helm..." >&2
  curl -sL https://get.helm.sh/helm-v3.14.0-linux-amd64.tar.gz | tar xz -C /tmp
  export PATH="/tmp/linux-amd64:${PATH}"
  chmod +x /tmp/linux-amd64/helm
  echo ">>> Helm installed: $(helm version --short)" >&2
fi

# Show configuration
echo ">>> Trustee charts: ${TRUSTEE_CHARTS_REPO} (ref: ${TRUSTEE_CHARTS_REF})"
if [[ -n "${TRUSTEE_CATALOG_SOURCE_IMAGE}" ]]; then
  echo ">>> Trustee catalog source: ${TRUSTEE_CATALOG_SOURCE_NAME} (image: ${TRUSTEE_CATALOG_SOURCE_IMAGE})"
else
  echo ">>> Trustee catalog source: ${TRUSTEE_CATALOG_SOURCE_NAME} (using existing catalog)"
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
    echo ">>> ERROR: Trustee operator installation failed"
    echo ">>> Namespace status:"
    oc get all -n "${TRUSTEE_NAMESPACE}" || true
    echo ">>> Operator logs:"
    oc logs -n "${TRUSTEE_NAMESPACE}" -l control-plane=controller-manager --tail=50 || true
  fi
}
trap 'exit_handler' EXIT

#========================================
# Helper Functions
#========================================

# Retry command up to 10 times with 30s delay between attempts
function retry() {
  "$@" && return 0
  for (( i = 0; i < 9; i++ )); do
    sleep 30
    "$@" && return 0
  done
  return 1
}

# Fetch trustee helm charts (from pre-built image or GitHub)
function fetch_trustee_charts() {
  local charts_dir="${SCRATCH}/charts"

  # Option 1: Extract from pre-built container image (preferred, works with restrict_network_access: true)
  # ci-operator provides built images via IMAGE_FORMAT and IMAGE_TRUSTEE_CHARTS env vars
  if [[ -n "${IMAGE_TRUSTEE_CHARTS:-}" ]]; then
    local charts_image="${IMAGE_TRUSTEE_CHARTS}"
    echo ">>> Extracting trustee charts from pre-built image" >&2
    echo ">>> Image: ${charts_image}" >&2

    # Extract charts from the image
    mkdir -p "${charts_dir}"
    local extract_output
    if extract_output=$(oc image extract "${charts_image}" --path /charts/:${charts_dir}/ 2>&1); then
      echo ">>> Charts extracted from image (no network access needed)" >&2
      echo ">>> Extracted files:" >&2
      ls -lR "${charts_dir}" | head -50 >&2
      # The git repo structure is: charts/trustee-operator/, so image has /charts/charts/
      # Return the nested charts directory
      echo "${charts_dir}/charts"
      return 0
    else
      echo ">>> ERROR: Failed to extract charts from image" >&2
      echo "$extract_output" >&2
      echo ">>> Falling back to git clone" >&2
    fi
  else
    echo ">>> IMAGE_TRUSTEE_CHARTS not set, using git clone fallback" >&2
  fi

  # Option 2: Fallback to git clone (requires restrict_network_access: false)
  echo ">>> Fetching trustee charts from GitHub: ${TRUSTEE_CHARTS_REPO} (ref: ${TRUSTEE_CHARTS_REF})" >&2

  if ! command -v git &> /dev/null; then
    echo ">>> ERROR: git command not found" >&2
    return 1
  fi

  git clone --depth 1 --branch "${TRUSTEE_CHARTS_REF}" "${TRUSTEE_CHARTS_REPO}" "${charts_dir}"

  if [[ ! -d "${charts_dir}" ]]; then
    echo ">>> ERROR: Failed to clone charts repository" >&2
    return 1
  fi

  echo ">>> Charts cloned from GitHub" >&2
  echo "${charts_dir}"
}

# Get cluster domain from ingress config, console route, or console URL
function get_cluster_domain() {
  local cluster_domain=""

  # Try ingress config, console route, then console URL
  cluster_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)

  if [[ -z "${cluster_domain}" ]]; then
    cluster_domain=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}' 2>/dev/null | sed 's/^console-openshift-console\.//' || true)
  fi

  if [[ -z "${cluster_domain}" ]]; then
    local console_url
    console_url=$(oc whoami --show-console 2>/dev/null || true)
    if [[ -n "${console_url}" ]]; then
      cluster_domain=$(echo "${console_url}" | sed 's|https://console-openshift-console\.||' | sed 's|/.*||')
    fi
  fi

  if [[ -z "${cluster_domain}" ]]; then
    echo ">>> ERROR: Failed to derive cluster domain" >&2
    return 1
  fi

  echo ">>> Cluster domain: ${cluster_domain}" >&2
  echo "${cluster_domain}"
}

#========================================
# Helm Chart Functions
#========================================

# Render trustee operator chart using helm template
function render_trustee_operator_chart() {
  local charts_dir="$1"
  local operator_chart="${charts_dir}/trustee-operator"

  if [[ ! -d "${operator_chart}" ]]; then
    echo ">>> ERROR: Operator chart not found at ${operator_chart}" >&2
    return 1
  fi

  echo ">>> Rendering trustee-operator chart from: ${operator_chart}" >&2
  echo ">>> Chart files:" >&2
  ls -la "${operator_chart}" >&2

  # Build helm command with --set parameters
  local helm_args=(
    "trustee-operator"
    "${operator_chart}"
    "--set" "namespaceOverride=${TRUSTEE_NAMESPACE}"
  )

  # Add catalog source configuration if custom image provided
  if [[ -n "${TRUSTEE_CATALOG_SOURCE_IMAGE}" ]]; then
    helm_args+=(
      "--set" "dev.image=${TRUSTEE_CATALOG_SOURCE_IMAGE}"
      "--set" "catalogSource.name=${TRUSTEE_CATALOG_SOURCE_NAME}"
    )
    echo ">>> Helm parameters: namespaceOverride=${TRUSTEE_NAMESPACE}, dev.image=${TRUSTEE_CATALOG_SOURCE_IMAGE}, catalogSource.name=${TRUSTEE_CATALOG_SOURCE_NAME}" >&2
  else
    echo ">>> Helm parameters: namespaceOverride=${TRUSTEE_NAMESPACE}" >&2
  fi

  # Render the chart and capture output for debugging
  local helm_output
  if ! helm_output=$(helm template "${helm_args[@]}" 2>&1); then
    echo ">>> ERROR: helm template failed" >&2
    echo "$helm_output" >&2
    return 1
  fi

  echo "$helm_output"
}

# Render trustee operands chart using helm template
function render_trustee_operands_chart() {
  local charts_dir="$1"
  local operands_chart="${charts_dir}/trustee-operands"

  if [[ ! -d "${operands_chart}" ]]; then
    echo ">>> ERROR: Operands chart not found at ${operands_chart}" >&2
    return 1
  fi

  echo ">>> Rendering trustee-operands chart from: ${operands_chart}" >&2
  echo ">>> Chart files:" >&2
  ls -la "${operands_chart}" >&2
  echo ">>> Helm parameters: namespaceOverride=${TRUSTEE_NAMESPACE}, clusterDomain=${CLUSTER_DOMAIN}" >&2

  # Render the chart and capture output for debugging
  local helm_output
  if ! helm_output=$(helm template trustee-operands "${operands_chart}" \
    --set "namespaceOverride=${TRUSTEE_NAMESPACE}" \
    --set "clusterDomain=${CLUSTER_DOMAIN}" 2>&1); then
    echo ">>> ERROR: helm template failed" >&2
    echo "$helm_output" >&2
    return 1
  fi

  echo "$helm_output"
}

#========================================
# Installation Functions
#========================================

# Install trustee operator via OLM using helm-rendered manifests
function install_trustee_operator() {
  local charts_dir="$1"

  echo ">>> Installing Trustee operator"

  # Render operator chart
  local operator_yaml="${SCRATCH}/operator-manifests.yaml"
  if ! render_trustee_operator_chart "${charts_dir}" > "${operator_yaml}"; then
    echo ">>> ERROR: Failed to render operator chart"
    return 1
  fi

  echo ">>> Rendered operator YAML (first 30 lines):"
  head -30 "${operator_yaml}"
  echo ">>> Total YAML lines: $(wc -l < "${operator_yaml}")"

  # Apply operator chart
  local apply_output
  if ! apply_output=$(oc apply -f "${operator_yaml}" 2>&1); then
    echo ">>> ERROR: Failed to apply operator manifests"
    echo "$apply_output"
    echo ">>> Full operator YAML:"
    cat "${operator_yaml}"
    return 1
  fi

  echo ">>> Apply output:"
  echo "$apply_output"
}

# Wait for operator installation through all OLM stages
# Stages: CatalogSource READY → Subscription → InstallPlan → CSV → Deployment
function wait_for_operator() {
  # Stage 1: Wait for CatalogSource to be READY (60s)
  # Skip if using existing catalog (no TRUSTEE_CATALOG_SOURCE_IMAGE provided)
  if [[ -n "${TRUSTEE_CATALOG_SOURCE_IMAGE}" ]]; then
    # Find the actual CatalogSource name that was created (helm chart creates trustee-operator-dev-catalog)
    local actual_catalog_name
    actual_catalog_name=$(oc get catalogsource -n openshift-marketplace -l olm.catalogSource!=redhat-operators -o name 2>/dev/null | grep -i trustee | head -1 | cut -d/ -f2 || echo "")

    if [[ -z "$actual_catalog_name" ]]; then
      # Fallback: try the name from env var
      actual_catalog_name="${TRUSTEE_CATALOG_SOURCE_NAME}"
    fi

    echo ">>> Waiting for CatalogSource ${actual_catalog_name} to be READY..."
    local catalog_ready=false
    for i in {1..12}; do
      local state
      state=$(oc get catalogsource -n openshift-marketplace "${actual_catalog_name}" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
      if [[ "${state}" == "READY" ]]; then
        echo ">>> CatalogSource ${actual_catalog_name} is READY"
        catalog_ready=true
        break
      fi
      [[ ${i} -lt 12 ]] && sleep 5
    done

    if [[ "${catalog_ready}" != "true" ]]; then
      echo ">>> ERROR: CatalogSource ${actual_catalog_name} not READY after 60s"
      echo ">>> All CatalogSources in openshift-marketplace:"
      oc get catalogsource -n openshift-marketplace || true
      echo ">>> Details of ${actual_catalog_name}:"
      oc get catalogsource -n openshift-marketplace "${actual_catalog_name}" -o yaml || true
      oc get pods -n openshift-marketplace -l olm.catalogSource="${actual_catalog_name}" || true
      oc describe pods -n openshift-marketplace -l olm.catalogSource="${actual_catalog_name}" | tail -50 || true
      return 1
    fi
  else
    echo ">>> Using existing CatalogSource ${TRUSTEE_CATALOG_SOURCE_NAME}, skipping readiness check"
  fi

  # Stage 2: Wait for Subscription to reference an InstallPlan (60s)
  echo ">>> Waiting for Subscription to reference InstallPlan..."
  local installplan_ref=""
  for i in {1..12}; do
    installplan_ref=$(oc get subscription -n "${TRUSTEE_NAMESPACE}" trustee-operator -o jsonpath='{.status.installplan.name}' 2>/dev/null || echo "")
    if [[ -n "${installplan_ref}" ]]; then
      echo ">>> Subscription references InstallPlan: ${installplan_ref}"
      break
    fi
    [[ ${i} -lt 12 ]] && sleep 5
  done

  if [[ -z "${installplan_ref}" ]]; then
    echo ">>> ERROR: Subscription has no InstallPlan reference after 60s"
    oc get subscription -n "${TRUSTEE_NAMESPACE}" trustee-operator -o yaml || true
    return 1
  fi

  # Stage 3: Wait for InstallPlan to be Complete (60s)
  echo ">>> Waiting for InstallPlan ${installplan_ref} to be Complete..."
  local installplan_complete=false
  for i in {1..12}; do
    local phase
    phase=$(oc get installplan -n "${TRUSTEE_NAMESPACE}" "${installplan_ref}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "${phase}" == "Complete" ]]; then
      echo ">>> InstallPlan is Complete"
      installplan_complete=true
      break
    fi
    [[ ${i} -lt 12 ]] && sleep 5
  done

  if [[ "${installplan_complete}" != "true" ]]; then
    echo ">>> ERROR: InstallPlan not Complete after 60s"
    oc get installplan -n "${TRUSTEE_NAMESPACE}" "${installplan_ref}" -o yaml || true
    return 1
  fi

  # Stage 4: Wait for CSV to be Succeeded (60s)
  echo ">>> Waiting for CSV to be Succeeded..."
  local csv_succeeded=false
  local csv_name=""
  for i in {1..12}; do
    local csv_phase
    csv_phase=$(oc get csv -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "${csv_phase}" == "Succeeded" ]]; then
      csv_name=$(oc get csv -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
      echo ">>> CSV ${csv_name} is Succeeded"
      csv_succeeded=true
      break
    fi
    [[ ${i} -lt 12 ]] && sleep 5
  done

  if [[ "${csv_succeeded}" != "true" ]]; then
    echo ">>> ERROR: CSV not Succeeded after 60s"
    oc get csv -n "${TRUSTEE_NAMESPACE}" -o yaml || true
    return 1
  fi

  # Export CSV name for kbs-client version mapping
  export TRUSTEE_CSV_NAME="${csv_name}"

  # Stage 5: Wait for Deployment to be Available (60s)
  echo ">>> Waiting for operator deployment to be Available..."
  local deployment_ready=false
  for i in {1..12}; do
    if oc get deployment -n "${TRUSTEE_NAMESPACE}" -l control-plane=controller-manager -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
      echo ">>> Operator deployment is Available"
      deployment_ready=true
      break
    fi
    [[ ${i} -lt 12 ]] && sleep 5
  done

  if [[ "${deployment_ready}" != "true" ]]; then
    echo ">>> ERROR: Operator deployment not Available after 60s"
    oc get deployment -n "${TRUSTEE_NAMESPACE}" || true
    oc get pods -n "${TRUSTEE_NAMESPACE}" || true
    oc describe pods -n "${TRUSTEE_NAMESPACE}" -l control-plane=controller-manager || true
    return 1
  fi

  echo ">>> Operator installation complete"
}

# Install Trustee operands using helm-rendered manifests
function install_trustee_operands() {
  local charts_dir="$1"

  echo ">>> Installing Trustee operands (cluster domain: ${CLUSTER_DOMAIN})"

  # Render operands chart
  local operands_yaml="${SCRATCH}/operands-manifests.yaml"
  if ! render_trustee_operands_chart "${charts_dir}" > "${operands_yaml}"; then
    echo ">>> ERROR: Failed to render operands chart"
    return 1
  fi

  echo ">>> Rendered operands YAML (first 30 lines):"
  head -30 "${operands_yaml}"
  echo ">>> Total YAML lines: $(wc -l < "${operands_yaml}")"

  # Apply operands chart
  local apply_output
  if ! apply_output=$(oc apply -f "${operands_yaml}" 2>&1); then
    echo ">>> ERROR: Failed to apply operands manifests"
    echo "$apply_output"
    echo ">>> Full operands YAML:"
    cat "${operands_yaml}"
    return 1
  fi

  echo ">>> Apply output:"
  echo "$apply_output"
}

# Wait for operand deployments to become available
function wait_for_operands() {
  sleep 10

  local operand_deployments
  operand_deployments=$(oc get deployment -n "${TRUSTEE_NAMESPACE}" -o name 2>/dev/null | grep -v controller-manager || true)

  if [[ -n "${operand_deployments}" ]]; then
    for deployment in ${operand_deployments}; do
      local deployment_ready=false
      for i in {1..10}; do
        if oc get "${deployment}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
          deployment_ready=true
          break
        fi
        [[ ${i} -lt 10 ]] && sleep 15
      done

      if [[ "${deployment_ready}" != "true" ]]; then
        echo ">>> WARNING: ${deployment} not ready after 150s"
        oc get "${deployment}" -n "${TRUSTEE_NAMESPACE}" || true
        oc describe "${deployment}" -n "${TRUSTEE_NAMESPACE}" || true
      fi
    done
  fi
}

#========================================
# Configuration Functions
#========================================

# Get TLS certificate for cluster ingress (tries multiple sources)
function get_tls_certificate() {
  local cert_data=""

  # Try router-ca, ingress-operator secrets, openssl, then any ingress secret
  if oc get secret -n openshift-ingress-operator router-ca &>/dev/null; then
    cert_data=$(oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || echo "")
  fi

  if [[ -z "${cert_data}" ]]; then
    local cert_secret
    cert_secret=$(oc get secret -n openshift-ingress-operator -o name 2>/dev/null | grep -E 'router-certs|ingress-operator' | head -1)
    if [[ -n "${cert_secret}" ]]; then
      cert_data=$(oc get "${cert_secret}" -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || echo "")
    fi
  fi

  if [[ -z "${cert_data}" ]] && [[ -n "${TRUSTEE_HOST}" ]]; then
    cert_data=$(echo | timeout 5 openssl s_client -connect "${TRUSTEE_HOST}:443" -servername "${TRUSTEE_HOST}" 2>/dev/null | openssl x509 2>/dev/null || echo "")
  fi

  if [[ -z "${cert_data}" ]]; then
    local cert_info
    cert_info=$(oc get secret -A -o json 2>/dev/null | jq -r '.items[] | select(.metadata.name | contains("ingress")) | select(.data."tls.crt" != null) | "\(.metadata.namespace)/\(.metadata.name)"' | head -1 || echo "")
    if [[ -n "${cert_info}" ]]; then
      local ns name
      ns=$(echo "${cert_info}" | cut -d/ -f1)
      name=$(echo "${cert_info}" | cut -d/ -f2)
      cert_data=$(oc get secret "${name}" -n "${ns}" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || echo "")
    fi
  fi

  [[ -z "${cert_data}" ]] && echo ">>> WARN: No TLS certificate found" >&2

  echo "${cert_data}"
}

# Get Trustee KBS service URL and save to SHARED_DIR
function get_trustee_url() {
  local kbs_service="kbs-service"
  local trustee_url=""
  local trustee_host=""
  local trustee_port=""

  trustee_port=$(oc get svc "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8080")

  # Try OpenShift route, LoadBalancer, then ClusterIP
  if oc get route -n "${TRUSTEE_NAMESPACE}" &>/dev/null; then
    trustee_host=$(oc get route "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [[ -n "${trustee_host}" ]]; then
      trustee_url="http://${trustee_host}"
      echo ">>> Trustee URL: ${trustee_url} (HTTP for test environment)"
    fi
  fi

  if [[ -z "${trustee_url}" ]]; then
    local trustee_ip
    trustee_ip=$(oc get svc "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    [[ -z "${trustee_ip}" ]] && trustee_ip=$(oc get svc "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    if [[ -n "${trustee_ip}" ]]; then
      trustee_url="http://${trustee_ip}:${trustee_port}"
      trustee_host="${trustee_ip}"
    fi
  fi

  if [[ -z "${trustee_url}" ]]; then
    local trustee_ip
    trustee_ip=$(oc get svc "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -n "${trustee_ip}" ]]; then
      echo ">>> WARN: Trustee using ClusterIP only (not externally accessible)"
      trustee_url="http://${trustee_ip}:${trustee_port}"
      trustee_host="${trustee_ip}"
    else
      echo ">>> ERROR: Cannot find Trustee KBS service in namespace ${TRUSTEE_NAMESPACE}"
      return 1
    fi
  fi

  echo "${trustee_url}" > "${SHARED_DIR}/TRUSTEE_URL"
  echo "${trustee_host}" > "${SHARED_DIR}/TRUSTEE_HOST"
  echo "${trustee_port}" > "${SHARED_DIR}/TRUSTEE_PORT"

  export TRUSTEE_URL="${trustee_url}"
  export TRUSTEE_HOST="${trustee_host}"
  export TRUSTEE_PORT="${trustee_port}"
}

# Create INITDATA for confidential containers (includes aa.toml, cdh.toml, policy.rego)
function create_initdata() {
  local tls_cert
  tls_cert=$(get_tls_certificate)

  local policy_data
  policy_data=$(oc get secret containers-policy -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.data.signed}' 2>/dev/null | base64 -d || echo "")

  if [[ -z "${policy_data}" ]]; then
    echo ">>> WARN: containers-policy secret not found, using default reject policy"
    policy_data='{
  "default": [
    {
      "type": "reject"
    }
  ],
  "transports": {
    "docker": {
      "ghcr.io/confidential-containers/test-container-image-rs": [
        {
          "type": "sigstoreSigned",
          "keyPath": "kbs:///default/cosign-keys/key-0"
        }
      ]
    }
  }
}'
  fi

  local policy_json
  if command -v jq &> /dev/null; then
    policy_json=$(echo "${policy_data}" | jq -c '.')
  else
    policy_json=$(echo "${policy_data}" | python3 -c 'import sys, json; print(json.dumps(json.load(sys.stdin), separators=(",", ":")))' 2>/dev/null || echo "${policy_data}")
  fi

  local initdata_file="${SCRATCH}/initdata.toml"

  cat > "${initdata_file}" <<EOF
algorithm = "sha256"
version = "0.1.0"

[data]
"aa.toml" = '''
[token_configs]
[token_configs.coco_as]
url = "${TRUSTEE_URL}"

[token_configs.kbs]
url = "${TRUSTEE_URL}"
cert = """${tls_cert}"""
'''

"cdh.toml"  = '''
socket = 'unix:///run/confidential-containers/cdh.sock'
credentials = []

[kbc]
name = "cc_kbc"
url = "${TRUSTEE_URL}"
kbs_cert = """${tls_cert}"""

[image]
image_security_policy = '${policy_json}'
'''

"policy.rego" = '''
package agent_policy

import future.keywords.in
import future.keywords.if
import future.keywords.every

default AddARPNeighborsRequest := true
default AddSwapRequest := true
default CloseStdinRequest := true
default CopyFileRequest := true
default CreateContainerRequest := true
default CreateSandboxRequest := true
default DestroySandboxRequest := true
default GetMetricsRequest := true
default GetOOMEventRequest := true
default GuestDetailsRequest := true
default ListInterfacesRequest := true
default ListRoutesRequest := true
default MemHotplugByProbeRequest := true
default OnlineCPUMemRequest := true
default PauseContainerRequest := true
default PullImageRequest := true
default ReadStreamRequest := false
default RemoveContainerRequest := true
default RemoveStaleVirtiofsShareMountsRequest := true
default ReseedRandomDevRequest := true
default ResumeContainerRequest := true
default SetGuestDateTimeRequest := true
default SignalProcessRequest := true
default StartContainerRequest := true
default StartTracingRequest := true
default StatsContainerRequest := true
default StopTracingRequest := true
default TtyWinResizeRequest := true
default UpdateContainerRequest := true
default UpdateEphemeralMountsRequest := true
default UpdateInterfaceRequest := true
default UpdateRoutesRequest := true
default WaitProcessRequest := true
default ExecProcessRequest := false
default SetPolicyRequest := true
default WriteStreamRequest := false

ExecProcessRequest if {
    input_command = concat(" ", input.process.Args)
    some allowed_command in policy_data.allowed_commands
    input_command == allowed_command
}

policy_data := {
  "allowed_commands": [
        "curl http://127.0.0.1:8006/cdh/resource/default/attestation-status/status",
        "curl http://127.0.0.1:8006/cdh/resource/default/attestation-status/random"
  ]
}
'''
EOF

  local encoded_initdata
  encoded_initdata=$(gzip -c "${initdata_file}" | base64 -w 0)

  echo "${encoded_initdata}" > "${SHARED_DIR}/INITDATA"
  cp "${initdata_file}" "${SHARED_DIR}/initdata.toml"

  export INITDATA="${encoded_initdata}"
}

# Update osc-config ConfigMap with Trustee URL and INITDATA
function update_env_configmap() {
  if ! oc get configmap osc-config -n default &>/dev/null; then
    echo ">>> WARN: osc-config ConfigMap not found (normal if env-cm step hasn't run yet)"
    return 0
  fi

  oc patch configmap osc-config -n default --type=json -p="[
    {\"op\": \"replace\", \"path\": \"/data/trusteeUrl\", \"value\": \"${TRUSTEE_URL}\"},
    {\"op\": \"replace\", \"path\": \"/data/INITDATA\", \"value\": \"${INITDATA}\"}
  ]"
}

#========================================
# Verification Functions
#========================================

# Generate kbs-client test pod manifest
function get_kbs_client_manifest() {
  cat << 'MANIFEST_EOF'
---
apiVersion: v1
kind: Pod
metadata:
  name: KBS_CLIENT_POD_PLACEHOLDER
  namespace: KBS_CLIENT_NAMESPACE_PLACEHOLDER
spec:
  containers:
  - name: kbs-client
    image: KBS_CLIENT_IMAGE_PLACEHOLDER
    command: ["sleep", "infinity"]
    securityContext:
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      seccompProfile:
        type: RuntimeDefault
      capabilities:
        drop:
        - ALL
  restartPolicy: Never
MANIFEST_EOF
}

# Map trustee operator version to compatible kbs-client version
function map_trustee_to_kbs_client_version() {
  local trustee_version="$1"
  case "${trustee_version}" in
    1.1.*|1.1)   echo "v0.17.0" ;;
    1.11.*|1.11) echo "v0.19.0" ;;
    *)           echo "" ;;  # No mapping exists
  esac
}

# Determine kbs-client image tag (from KBS_CLIENT_TAG, trustee CSV, or auto-discover)
function get_kbs_client_tag() {
  # 1. Use explicit override if provided
  if [[ -n "${KBS_CLIENT_TAG:-}" ]]; then
    echo ">>> kbs-client tag (from KBS_CLIENT_TAG): ${KBS_CLIENT_TAG}" >&2
    echo "${KBS_CLIENT_TAG}"
    return 0
  fi

  # 2. Try to map from trustee operator CSV version
  if [[ -n "${TRUSTEE_CSV_NAME:-}" ]]; then
    # Extract version from CSV name (e.g., "trustee-operator.v1.10.0" -> "1.10.0")
    local trustee_version
    trustee_version=$(echo "${TRUSTEE_CSV_NAME}" | sed 's/^trustee-operator\.v//')

    if [[ -n "${trustee_version}" ]]; then
      # Try major.minor mapping first (e.g., "1.10.0" -> "1.10")
      local trustee_minor="${trustee_version%.*}"
      local mapped_tag
      mapped_tag=$(map_trustee_to_kbs_client_version "${trustee_minor}")

      if [[ -n "${mapped_tag}" ]]; then
        echo ">>> kbs-client tag (mapped from trustee ${trustee_version}): ${mapped_tag}" >&2
        echo "${mapped_tag}"
        return 0
      fi

      # Try full version mapping if minor didn't match
      mapped_tag=$(map_trustee_to_kbs_client_version "${trustee_version}")
      if [[ -n "${mapped_tag}" ]]; then
        echo ">>> kbs-client tag (mapped from trustee ${trustee_version}): ${mapped_tag}" >&2
        echo "${mapped_tag}"
        return 0
      fi
    fi
  fi

  # 3. Auto-discover latest semver tag from registry
  local latest_tag=""
  latest_tag=$(skopeo list-tags docker://quay.io/confidential-containers/kbs-client 2>/dev/null | \
    jq -r '.Tags[]' | \
    grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | \
    sort -V | \
    tail -1 || echo "")

  if [[ -n "${latest_tag}" ]]; then
    echo ">>> kbs-client tag (auto-discovered latest semver): ${latest_tag}" >&2
    echo "${latest_tag}"
    return 0
  fi

  # 4. Fallback to known-good version
  echo ">>> WARN: Could not determine kbs-client tag, using fallback: v0.17.0" >&2
  echo "v0.17.0"
}

# Verify Trustee KBS connectivity using kbs-client test pod
function verify_trustee_connectivity() {
  local kbs_client_pod="kbs-client-test"
  local kbs_client_namespace="${TRUSTEE_NAMESPACE}"
  local kbs_client_tag
  kbs_client_tag=$(get_kbs_client_tag)
  local kbs_client_image="quay.io/confidential-containers/kbs-client:${kbs_client_tag}"

  echo ">>> Creating kbs-client test pod (image: ${kbs_client_image})"
  get_kbs_client_manifest | \
    sed "s@KBS_CLIENT_POD_PLACEHOLDER@${kbs_client_pod}@g" | \
    sed "s@KBS_CLIENT_NAMESPACE_PLACEHOLDER@${kbs_client_namespace}@g" | \
    sed "s@KBS_CLIENT_IMAGE_PLACEHOLDER@${kbs_client_image}@g" | \
    oc apply -f -

  # Wait for pod to become ready
  local pod_ready=false
  for i in {1..10}; do
    if oc get pod/${kbs_client_pod} -n ${kbs_client_namespace} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
      pod_ready=true
      break
    fi
    [[ ${i} -lt 10 ]] && sleep 15
  done

  if [[ "${pod_ready}" != "true" ]]; then
    echo ">>> ERROR: kbs-client pod not ready after 150s"
    oc describe pod/${kbs_client_pod} -n ${kbs_client_namespace} || true
    oc logs pod/${kbs_client_pod} -n ${kbs_client_namespace} || true
    oc delete pod/${kbs_client_pod} -n ${kbs_client_namespace} --ignore-not-found=true
    return 1
  fi

  # Test KBS connectivity using RCA protocol
  # The kbs-client performs Remote Attestation Protocol (RCA):
  #   1. GET resource → 401 (no token)
  #   2. POST /auth + POST /attest (get attestation token)
  #   3. GET resource → 200 (with token)
  local kbs_test_failed=false
  echo ">>> Testing KBS connectivity: ${TRUSTEE_URL}/default/kbsres1/key1"
  if oc exec ${kbs_client_pod} -n ${kbs_client_namespace} -- \
    kbs-client --url "${TRUSTEE_URL}" get-resource --path default/kbsres1/key1 \
    > /tmp/kbs-resource.txt 2> /tmp/kbs-stderr.txt; then

    # Success
    echo ">>> Successfully retrieved default/kbsres1/key1"
    local resource_value
    resource_value=$(cat /tmp/kbs-resource.txt 2>/dev/null || echo "")
    echo ">>> Resource value: ${resource_value}"

    kbs_test_failed=false
  else
    # Failure - show diagnostics
    echo ">>> ERROR: Failed to retrieve resource from Trustee KBS at ${TRUSTEE_URL}"

    # Show stderr (has the actual error)
    if [[ -s /tmp/kbs-stderr.txt ]]; then
      echo ">>> Error output:"
      cat /tmp/kbs-stderr.txt
    fi

    # Show stdout (might have partial data)
    if [[ -s /tmp/kbs-resource.txt ]]; then
      echo ">>> Partial output:"
      cat /tmp/kbs-resource.txt
    fi

    # Check for specific error patterns in both stdout and stderr
    local all_output
    all_output="$(cat /tmp/kbs-resource.txt /tmp/kbs-stderr.txt 2>/dev/null || true)"

    if echo "${all_output}" | grep -q "404\|not found\|NotFound"; then
      echo ">>> ERROR: Resource not found (404) - KbsConfig may not have published secrets correctly"
    fi
    if echo "${all_output}" | grep -q "Connection refused\|Connection timed out\|timed out"; then
      echo ">>> ERROR: Cannot connect to KBS service"
    fi
    if echo "${all_output}" | grep -q "certificate verify failed\|SSL\|TLS"; then
      echo ">>> ERROR: SSL/TLS error - URL should be HTTP, not HTTPS (current: ${TRUSTEE_URL})"
    fi

    kbs_test_failed=true
  fi

  # Capture KBS logs for debugging (shows RCA protocol flow)
  local kbs_pod
  kbs_pod=$(oc get pod -n "${TRUSTEE_NAMESPACE}" -l app=kbs -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "${kbs_pod}" ]]; then
    local log_file="${ARTIFACT_DIR:-${SHARED_DIR}}/kbs-attestation-logs.txt"
    # Strip ANSI color codes from logs for cleaner output
    oc logs "${kbs_pod}" -n "${TRUSTEE_NAMESPACE}" --since=5m 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "${log_file}" || true

    if [[ -n "${ARTIFACT_DIR}" && "${ARTIFACT_DIR}" != "${SHARED_DIR}" ]]; then
      cp "${log_file}" "${SHARED_DIR}/kbs-attestation-logs.txt" 2>/dev/null || true
    fi

    # Show attestation patterns (RCA protocol flow)
    echo ">>> Attestation patterns (RCA protocol):"
    if grep -q "POST.*attest" "${log_file}" 2>/dev/null; then
      echo "✓ Attestation (POST /auth, POST /attest):"
      grep -E "POST.*/auth|POST.*attest" "${log_file}" | tail -4
    else
      echo "⚠ No attestation POST requests"
    fi

    if grep -q "GET.*resource" "${log_file}" 2>/dev/null; then
      echo "✓ Resource access (GET → 401 → attest → GET → 200):"
      grep "GET.*resource" "${log_file}" | tail -5
    else
      echo "⚠ No resource GET requests"
    fi
  else
    echo ">>> WARN: Could not find KBS pod"
    oc get pods -n "${TRUSTEE_NAMESPACE}" || true
  fi

  oc delete pod/${kbs_client_pod} -n ${kbs_client_namespace} --ignore-not-found=true

  if [[ "${kbs_test_failed}" == "true" ]]; then
    echo ">>> ERROR: kbs-client connectivity test failed"
    return 1
  fi

  return 0
}

#========================================
# Main Execution
#========================================

echo ">>> Starting Trustee operator installation"

# Fetch helm charts from GitHub
CHARTS_DIR=$(fetch_trustee_charts)
export CHARTS_DIR

# Get cluster domain
CLUSTER_DOMAIN=$(get_cluster_domain)
export CLUSTER_DOMAIN

# Install operator and operands
install_trustee_operator "${CHARTS_DIR}"
wait_for_operator
install_trustee_operands "${CHARTS_DIR}"
wait_for_operands

# Configure and verify
get_trustee_url
create_initdata
update_env_configmap
verify_trustee_connectivity

echo ">>> Trustee operator installation complete"
echo ">>> KBS URL: ${TRUSTEE_URL}"
echo ">>> INITDATA saved to: ${SHARED_DIR}/INITDATA"
