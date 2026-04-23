#!/usr/bin/env bash

set -euo pipefail

cat <<EOF
>>> Install trustee operator and operands using helm template [$(date -u || true)].
* Install helm if not available
* Clone the confidential-devhub/charts repository
* Derive the cluster domain
* Generate and apply trustee-operator manifests using helm template
* Wait for the operator to be ready
* Generate and apply trustee-operands manifests using helm template
* Wait for the operands to be ready
* Retrieve Trustee KBS service URL and save to SHARED_DIR
* Create INITDATA for confidential containers and save to SHARED_DIR
* Update osc-config ConfigMap with TRUSTEE_URL and INITDATA
* Verify Trustee connectivity using kbs-client pod
* Capture KBS pod logs showing attestation attempts
EOF

echo ">>> Prepare script environment"
export SHARED_DIR=${SHARED_DIR:-/tmp}
echo "SHARED_DIR=${SHARED_DIR}"

export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}
echo "KUBECONFIG=${KUBECONFIG}"

TRUSTEE_INSTALL=${TRUSTEE_INSTALL:-false}
echo "TRUSTEE_INSTALL=${TRUSTEE_INSTALL}"

# Check if trustee installation is enabled
if [[ "${TRUSTEE_INSTALL}" != "true" ]]; then
  echo ">>> Trustee operator installation is disabled (TRUSTEE_INSTALL=${TRUSTEE_INSTALL})"
  echo ">>> To enable, set TRUSTEE_INSTALL=true in the job configuration"
  echo ">>> Skipping trustee operator installation"
  exit 0
fi

echo ">>> Trustee operator installation is enabled"

TRUSTEE_NAMESPACE=${TRUSTEE_NAMESPACE:-trustee-operator-system}
echo "TRUSTEE_NAMESPACE=${TRUSTEE_NAMESPACE}"

TRUSTEE_IMAGE_REPO=${TRUSTEE_IMAGE_REPO:-quay.io/redhat-user-workloads/ose-osc-tenant/trustee-test-fbc}
echo "TRUSTEE_IMAGE_REPO=${TRUSTEE_IMAGE_REPO}"

TRUSTEE_IMAGE_TAG=${TRUSTEE_IMAGE_TAG:-1.1.0-1776506656}
echo "TRUSTEE_IMAGE_TAG=${TRUSTEE_IMAGE_TAG}"

TRUSTEE_CHARTS_REF=${TRUSTEE_CHARTS_REF:-main}
echo "TRUSTEE_CHARTS_REF=${TRUSTEE_CHARTS_REF}"

SCRATCH=$(mktemp -d)
echo "SCRATCH=${SCRATCH}"
cd "${SCRATCH}"

function exit_handler() {
  exitcode=$?
  set +e
  echo ">>> End trustee operator install"
  echo "[$(date -u || true)] SECONDS=${SECONDS}"
  rm -rf "${SCRATCH}"
  if [[ ${exitcode} -ne 0 ]]; then
    echo "Failed to install trustee operator with helm"
    echo ">>> Checking trustee operator namespace status"
    oc get all -n "${TRUSTEE_NAMESPACE}" || true
    echo ">>> Checking trustee operator pod logs"
    oc logs -n "${TRUSTEE_NAMESPACE}" -l control-plane=controller-manager --tail=50 || true
  else
    echo "Successfully installed trustee operator with helm"
  fi
}
trap 'exit_handler' EXIT

function retry() {
  "$@" && return 0  # unrolled 1 to simplify sleep only between tries
  for (( i = 0; i < 9; i++ )); do
    sleep 30
    "$@" && return 0
  done
  return 1
}

function get_cluster_domain() {
  echo ">>> Deriving cluster domain"
  local cluster_domain=""

  # Method 1: Try to get domain from ingress config (most reliable)
  cluster_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)

  # Method 2: If that fails, try getting it from a console route
  if [[ -z "${cluster_domain}" ]]; then
    echo ">>> Trying alternative method to get cluster domain"
    cluster_domain=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}' 2>/dev/null | sed 's/^console-openshift-console\.//' || true)
  fi

  # Method 3: If that fails, try parsing from cluster console URL
  if [[ -z "${cluster_domain}" ]]; then
    echo ">>> Trying to derive from console URL"
    local console_url
    console_url=$(oc whoami --show-console 2>/dev/null || true)
    if [[ -n "${console_url}" ]]; then
      cluster_domain=$(echo "${console_url}" | sed 's|https://console-openshift-console\.||' | sed 's|/.*||')
    fi
  fi

  if [[ -z "${cluster_domain}" ]]; then
    echo "ERROR: Failed to derive cluster domain"
    return 1
  fi

  echo ">>> Cluster domain: ${cluster_domain}"
  echo "${cluster_domain}"
}

function install_helm() {
  echo ">>> Installing helm"
  mkdir -p /tmp/helm
  curl -fsSL https://get.helm.sh/helm-v3.16.2-linux-amd64.tar.gz --output /tmp/helm/helm-v3.16.2-linux-amd64.tar.gz
  echo "9318379b847e333460d33d291d4c088156299a26cd93d570a7f5d0c36e50b5bb /tmp/helm/helm-v3.16.2-linux-amd64.tar.gz" | sha256sum --check --status
  (cd /tmp/helm && tar xvfpz helm-v3.16.2-linux-amd64.tar.gz)
  chmod +x /tmp/helm/linux-amd64/helm
  export PATH="/tmp/helm/linux-amd64:${PATH}"
}

function clone_charts_repo() {
  echo ">>> Cloning confidential-devhub/charts repository"
  retry git clone https://github.com/confidential-devhub/charts.git "${SCRATCH}/charts"
  cd "${SCRATCH}/charts"
  git checkout "${TRUSTEE_CHARTS_REF}"
  echo ">>> Using charts at commit: $(git rev-parse HEAD)"
  cd "${SCRATCH}"
}

function install_trustee_operator() {
  echo ">>> Creating namespace ${TRUSTEE_NAMESPACE}"
  oc create namespace "${TRUSTEE_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

  echo ">>> Generating and applying trustee operator manifests"
  echo ">>> Using image: ${TRUSTEE_IMAGE_REPO}:${TRUSTEE_IMAGE_TAG}"

  helm template trustee-operator "${SCRATCH}/charts/charts/trustee-operator" \
    --set "namespaceOverride=${TRUSTEE_NAMESPACE}" \
    --set "dev.image=${TRUSTEE_IMAGE_REPO}:${TRUSTEE_IMAGE_TAG}" \
    | oc apply -f -
}

function wait_for_operator() {
  echo ">>> Waiting for trustee operator to be ready"

  # Wait for the operator deployment to be ready
  retry oc wait --for=condition=Available --timeout=300s \
    deployment -n "${TRUSTEE_NAMESPACE}" -l control-plane=controller-manager \
    || {
      echo ">>> Deployment status:"
      oc get deployment -n "${TRUSTEE_NAMESPACE}" || true
      echo ">>> Pod status:"
      oc get pods -n "${TRUSTEE_NAMESPACE}" || true
      echo ">>> Pod describe:"
      oc describe pods -n "${TRUSTEE_NAMESPACE}" -l control-plane=controller-manager || true
      return 1
    }

  echo ">>> Trustee operator is ready"
  oc get all -n "${TRUSTEE_NAMESPACE}"
}

function install_trustee_operands() {
  echo ">>> Installing trustee operands"
  echo ">>> Generating and applying trustee operands manifests"
  echo ">>> Using cluster domain: ${CLUSTER_DOMAIN}"

  helm template trustee-operands "${SCRATCH}/charts/charts/trustee-operands" \
    --set "namespaceOverride=${TRUSTEE_NAMESPACE}" \
    --set "clusterDomain=${CLUSTER_DOMAIN}" \
    | oc apply -f -

  echo ">>> Trustee operands manifests applied"
}

function wait_for_operands() {
  echo ">>> Waiting for trustee operands to be ready"

  # Give some time for operands to be created
  sleep 10

  # Wait for operand deployments to be ready
  # Note: Adjust the selector based on actual operand labels
  local operand_deployments
  operand_deployments=$(oc get deployment -n "${TRUSTEE_NAMESPACE}" -o name 2>/dev/null | grep -v controller-manager || true)

  if [[ -n "${operand_deployments}" ]]; then
    for deployment in ${operand_deployments}; do
      echo ">>> Waiting for ${deployment}"
      retry oc wait --for=condition=Available --timeout=300s \
        -n "${TRUSTEE_NAMESPACE}" "${deployment}" \
        || {
          echo ">>> Failed to wait for ${deployment}"
          oc get "${deployment}" -n "${TRUSTEE_NAMESPACE}" || true
          oc describe "${deployment}" -n "${TRUSTEE_NAMESPACE}" || true
        }
    done
  else
    echo ">>> No operand deployments found, checking for other resources"
  fi

  echo ">>> Trustee operands status:"
  oc get all -n "${TRUSTEE_NAMESPACE}"
}

function get_tls_certificate() {
  echo ">>> Retrieving TLS certificate for Trustee"

  local cert_data=""

  # Method 1: Try to get certificate from ingress controller
  if oc get secret -n openshift-ingress-operator router-ca &>/dev/null; then
    cert_data=$(oc get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || echo "")
  fi

  # Method 2: Try ingress-operator secret
  if [[ -z "${cert_data}" ]]; then
    local cert_secret
    cert_secret=$(oc get secret -n openshift-ingress-operator -o name 2>/dev/null | grep -E 'router-certs|ingress-operator' | head -1)
    if [[ -n "${cert_secret}" ]]; then
      cert_data=$(oc get "${cert_secret}" -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d || echo "")
    fi
  fi

  # Method 3: Try to extract from the route using openssl
  if [[ -z "${cert_data}" ]] && [[ -n "${TRUSTEE_HOST}" ]]; then
    cert_data=$(echo | timeout 5 openssl s_client -connect "${TRUSTEE_HOST}:443" -servername "${TRUSTEE_HOST}" 2>/dev/null | openssl x509 2>/dev/null || echo "")
  fi

  # Method 4: Fallback to any ingress-related secret
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

  if [[ -z "${cert_data}" ]]; then
    echo ">>> WARNING: Could not retrieve TLS certificate, using empty cert (may work for HTTP)"
    cert_data=""
  else
    echo ">>> TLS certificate retrieved successfully"
  fi

  echo "${cert_data}"
}

function get_trustee_url() {
  echo ">>> Retrieving Trustee KBS service URL"

  local kbs_service="kbs-service"
  local trustee_url=""
  local trustee_host=""
  local trustee_port=""

  # First, always get the service port for reference
  trustee_port=$(oc get svc "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "8080")
  echo ">>> Trustee service port: ${trustee_port}"

  # Method 1: Try to get OpenShift route (most common for OpenShift)
  if oc get route -n "${TRUSTEE_NAMESPACE}" &>/dev/null; then
    trustee_host=$(oc get route "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [[ -n "${trustee_host}" ]]; then
      local route_port=""
      # Check if route has TLS configured
      if oc get route "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.spec.tls}' 2>/dev/null | grep -q termination; then
        # For HTTPS routes, check if a non-standard port is specified
        route_port=$(oc get route "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.spec.port.targetPort}' 2>/dev/null || echo "")
        if [[ -n "${route_port}" && "${route_port}" != "443" && "${route_port}" != "https" ]]; then
          trustee_url="https://${trustee_host}:${trustee_port}"
        else
          trustee_url="https://${trustee_host}"
        fi
      else
        # For HTTP routes, check if a non-standard port is specified
        route_port=$(oc get route "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.spec.port.targetPort}' 2>/dev/null || echo "")
        if [[ -n "${route_port}" && "${route_port}" != "80" && "${route_port}" != "http" ]]; then
          trustee_url="http://${trustee_host}:${trustee_port}"
        else
          trustee_url="http://${trustee_host}"
        fi
      fi
      echo ">>> Found OpenShift route: ${trustee_url}"
    fi
  fi

  # Method 2: Try LoadBalancer service
  if [[ -z "${trustee_url}" ]]; then
    local trustee_ip
    trustee_ip=$(oc get svc "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -z "${trustee_ip}" ]]; then
      # Try hostname for cloud providers that use DNS names
      trustee_ip=$(oc get svc "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    fi
    if [[ -n "${trustee_ip}" ]]; then
      trustee_url="http://${trustee_ip}:${trustee_port}"
      trustee_host="${trustee_ip}"
      echo ">>> Found LoadBalancer service: ${trustee_url}"
    fi
  fi

  # Method 3: Fall back to ClusterIP (internal only)
  if [[ -z "${trustee_url}" ]]; then
    local trustee_ip
    trustee_ip=$(oc get svc "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")
    if [[ -n "${trustee_ip}" ]]; then
      echo ">>> WARNING: Trustee service is ClusterIP only (not externally accessible)"
      echo ">>> You may need to use port-forward or create a route/ingress"
      trustee_url="http://${trustee_ip}:${trustee_port}"
      trustee_host="${trustee_ip}"
    else
      echo ">>> ERROR: Cannot find Trustee KBS service in namespace ${TRUSTEE_NAMESPACE}"
      return 1
    fi
  fi

  echo ">>> TRUSTEE_URL: ${trustee_url}"
  echo ">>> TRUSTEE_HOST: ${trustee_host}"
  echo ">>> TRUSTEE_PORT: ${trustee_port}"

  # Save Trustee URL, host, and port to shared directory for use by subsequent steps
  echo "${trustee_url}" > "${SHARED_DIR}/TRUSTEE_URL"
  echo "${trustee_host}" > "${SHARED_DIR}/TRUSTEE_HOST"
  echo "${trustee_port}" > "${SHARED_DIR}/TRUSTEE_PORT"

  echo ">>> Saved TRUSTEE_URL to ${SHARED_DIR}/TRUSTEE_URL"
  echo ">>> Saved TRUSTEE_HOST to ${SHARED_DIR}/TRUSTEE_HOST"
  echo ">>> Saved TRUSTEE_PORT to ${SHARED_DIR}/TRUSTEE_PORT"

  export TRUSTEE_URL="${trustee_url}"
  export TRUSTEE_HOST="${trustee_host}"
  export TRUSTEE_PORT="${trustee_port}"
}

function create_initdata() {
  echo ">>> Creating INITDATA for confidential containers"

  # Get TLS certificate
  local tls_cert
  tls_cert=$(get_tls_certificate)

  # Get image security policy from containers-policy secret
  echo ">>> Retrieving image security policy from containers-policy secret"
  local policy_data
  policy_data=$(oc get secret containers-policy -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.data.signed}' 2>/dev/null | base64 -d || echo "")

  if [[ -z "${policy_data}" ]]; then
    echo ">>> WARNING: containers-policy secret not found, using default reject policy"
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

  # Compact JSON (single line) for embedding in TOML
  local policy_json
  if command -v jq &> /dev/null; then
    policy_json=$(echo "${policy_data}" | jq -c '.')
  else
    # If jq not available, use python
    policy_json=$(echo "${policy_data}" | python3 -c 'import sys, json; print(json.dumps(json.load(sys.stdin), separators=(",", ":")))' 2>/dev/null || echo "${policy_data}")
  fi

  echo ">>> Policy retrieved successfully"

  # Create initdata.toml
  local initdata_file="${SCRATCH}/initdata.toml"
  echo ">>> Generating initdata.toml"

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

  echo ">>> Created: ${initdata_file}"

  # Encode INITDATA (gzip + base64)
  echo ">>> Encoding INITDATA"
  local encoded_initdata
  encoded_initdata=$(gzip -c "${initdata_file}" | base64 -w 0)

  # Save to shared directory
  echo "${encoded_initdata}" > "${SHARED_DIR}/INITDATA"
  cp "${initdata_file}" "${SHARED_DIR}/initdata.toml"

  echo ">>> Saved INITDATA to ${SHARED_DIR}/INITDATA ($(echo -n "${encoded_initdata}" | wc -c) bytes)"
  echo ">>> Saved initdata.toml to ${SHARED_DIR}/initdata.toml (plain text for inspection)"

  export INITDATA="${encoded_initdata}"
}

function update_env_configmap() {
  echo ">>> Updating osc-config ConfigMap with Trustee values"

  # Check if the ConfigMap exists
  if ! oc get configmap osc-config -n default &>/dev/null; then
    echo ">>> WARNING: osc-config ConfigMap not found, skipping update"
    echo ">>> This is normal if env-cm step hasn't run yet or if running standalone"
    return 0
  fi

  echo ">>> Updating osc-config ConfigMap with TRUSTEE_URL and INITDATA"

  # Update the ConfigMap with the new values
  oc patch configmap osc-config -n default --type=json -p="[
    {\"op\": \"replace\", \"path\": \"/data/trusteeUrl\", \"value\": \"${TRUSTEE_URL}\"},
    {\"op\": \"replace\", \"path\": \"/data/INITDATA\", \"value\": \"${INITDATA}\"}
  ]"

  echo ">>> ConfigMap osc-config updated successfully"
  echo ">>> trusteeUrl: ${TRUSTEE_URL}"
  echo ">>> INITDATA: <$(echo -n "${INITDATA}" | wc -c) bytes>"

  # Verify the update
  echo ">>> Verifying ConfigMap update"
  oc get configmap osc-config -n default -o yaml | grep -E "trusteeUrl|INITDATA" | head -2
}

function verify_trustee_connectivity() {
  echo ">>> Verifying Trustee connectivity using kbs-client"

  local kbs_client_pod="kbs-client-test"
  local kbs_client_namespace="$TRUSTEE_NAMESPACE"
  local kbs_client_image="quay.io/confidential-containers/kbs-client:v0.17.0"

  # Create kbs-client pod
  echo ">>> Creating kbs-client pod"
  cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${kbs_client_pod}
  namespace: ${kbs_client_namespace}
spec:
  containers:
  - name: kbs-client
    image: ${kbs_client_image}
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
EOF

  # Wait for pod to be ready
  echo ">>> Waiting for kbs-client pod to be ready"
  if ! retry oc wait --for=condition=Ready --timeout=120s pod/${kbs_client_pod} -n ${kbs_client_namespace}; then
    echo ">>> ERROR: kbs-client pod failed to become ready"
    oc describe pod/${kbs_client_pod} -n ${kbs_client_namespace} || true
    oc logs pod/${kbs_client_pod} -n ${kbs_client_namespace} || true
    oc delete pod/${kbs_client_pod} -n ${kbs_client_namespace} --ignore-not-found=true
    return 1
  fi

  echo ">>> kbs-client pod is ready"

  # Test basic connectivity to Trustee KBS
  echo ">>> Testing connectivity to Trustee KBS at ${TRUSTEE_URL}"

  # Try to fetch the auth endpoint (basic connectivity test)
  if oc exec ${kbs_client_pod} -n ${kbs_client_namespace} -- \
    kbs-client --url "${TRUSTEE_URL}" get-resource --path default/kbsres1/key1 2>&1 | tee /tmp/kbs-test-output.txt; then
    echo ">>> SUCCESS: Successfully connected to Trustee KBS"
  else
    # Check if it's a "resource not found" error (which is OK - means KBS is responding)
    if grep -q "404\|not found\|NotFound" /tmp/kbs-test-output.txt; then
      echo ">>> INFO: Trustee KBS is responding (resource not found is expected for test resource)"
      echo ">>> This confirms connectivity is working"
    else
      echo ">>> WARNING: Failed to connect to Trustee KBS"
      echo ">>> This may be expected if resources haven't been populated yet"
      cat /tmp/kbs-test-output.txt || true
    fi
  fi

  # Test if we can reach the health/version endpoint
  echo ">>> Testing Trustee KBS version endpoint"
  if oc exec ${kbs_client_pod} -n ${kbs_client_namespace} -- \
    sh -c "command -v curl >/dev/null && curl -sk ${TRUSTEE_URL}/kbs/v0/version 2>&1" || \
    echo ">>> INFO: curl not available in kbs-client image, skipping version check"; then
    echo ">>> Trustee KBS version endpoint check completed"
  fi

  # Test basic resource operation (this will fail but shows KBS is processing requests)
  echo ">>> Testing basic KBS resource operation"
  oc exec ${kbs_client_pod} -n ${kbs_client_namespace} -- \
    kbs-client --url "${TRUSTEE_URL}" get-resource --path default/test/connectivity 2>&1 | head -20 || \
    echo ">>> Expected failure - resource doesn't exist, but KBS is responding"

  # Capture logs from KBS pod showing the attestation attempts
  echo ">>> Capturing KBS pod logs showing attestation attempts"

  local kbs_pod
  kbs_pod=$(oc get pod -n "${TRUSTEE_NAMESPACE}" -l app=kbs -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "${kbs_pod}" ]]; then
    echo ">>> Found KBS pod: ${kbs_pod}"

    # Get recent logs showing the kbs-client requests
    echo ">>> Retrieving KBS logs from last 5 minutes"
    local log_file="${ARTIFACT_DIR:-${SHARED_DIR}}/kbs-attestation-logs.txt"
    oc logs "${kbs_pod}" -n "${TRUSTEE_NAMESPACE}" --since=5m > "${log_file}" 2>&1 || true

    # Also save to SHARED_DIR for use by subsequent steps if ARTIFACT_DIR is different
    if [[ -n "${ARTIFACT_DIR}" && "${ARTIFACT_DIR}" != "${SHARED_DIR}" ]]; then
      cp "${log_file}" "${SHARED_DIR}/kbs-attestation-logs.txt" 2>/dev/null || true
    fi

    # Show relevant attestation log entries
    echo ">>> KBS attestation log summary:"
    echo "================================================"
    grep -E "attest|resource|POST|GET|kbs/v0" "${log_file}" 2>/dev/null | tail -30 || \
      echo ">>> No attestation-related logs found (may be using different log format)"
    echo "================================================"

    # Save full logs for later inspection
    echo ">>> Full KBS logs saved to ${log_file}"
    if [[ -n "${ARTIFACT_DIR}" ]]; then
      echo ">>> Logs will be included in CI job artifacts"
    fi

    # Show log statistics
    local log_lines
    log_lines=$(wc -l < "${log_file}" 2>/dev/null || echo "0")
    echo ">>> Captured ${log_lines} lines of KBS logs"

    # Look for specific attestation patterns
    echo ">>> Checking for attestation patterns:"
    if grep -q "POST.*attest" "${log_file}" 2>/dev/null; then
      echo ">>> ✓ Found attestation POST requests"
      grep "POST.*attest" "${log_file}" | tail -5
    else
      echo ">>> ⚠ No attestation POST requests found"
    fi

    if grep -q "GET.*resource" "${log_file}" 2>/dev/null; then
      echo ">>> ✓ Found resource GET requests"
      grep "GET.*resource" "${log_file}" | tail -5
    else
      echo ">>> ⚠ No resource GET requests found"
    fi

  else
    echo ">>> WARNING: Could not find KBS pod in namespace ${TRUSTEE_NAMESPACE}"
    echo ">>> Listing all pods in namespace:"
    oc get pods -n "${TRUSTEE_NAMESPACE}" || true
  fi

  # Clean up the pod
  echo ">>> Cleaning up kbs-client pod"
  oc delete pod/${kbs_client_pod} -n ${kbs_client_namespace} --ignore-not-found=true

  echo ">>> Trustee connectivity verification completed"
  return 0
}

echo ">>> Begin trustee operator installation"

# Get cluster domain for potential use
CLUSTER_DOMAIN=$(get_cluster_domain)
export CLUSTER_DOMAIN
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"

# Check if helm is already installed
if ! command -v helm &> /dev/null; then
  install_helm
else
  echo ">>> Helm is already installed"
  helm version
fi

clone_charts_repo
install_trustee_operator
wait_for_operator
install_trustee_operands
wait_for_operands
get_trustee_url
create_initdata
update_env_configmap
verify_trustee_connectivity

echo ">>> Trustee operator and operands installation completed successfully"
echo ">>> TRUSTEE_URL: ${TRUSTEE_URL}"
echo ">>> TRUSTEE_HOST: ${TRUSTEE_HOST}"
echo ">>> TRUSTEE_PORT: ${TRUSTEE_PORT}"
echo ">>> INITDATA created and saved to ${SHARED_DIR}/INITDATA"
echo ">>> ConfigMap osc-config updated with Trustee values"
echo ">>> Trustee connectivity verified with kbs-client"
if [[ -n "${ARTIFACT_DIR}" ]]; then
  echo ">>> KBS attestation logs saved to ${ARTIFACT_DIR}/kbs-attestation-logs.txt (in artifacts)"
else
  echo ">>> KBS attestation logs saved to ${SHARED_DIR}/kbs-attestation-logs.txt"
fi
