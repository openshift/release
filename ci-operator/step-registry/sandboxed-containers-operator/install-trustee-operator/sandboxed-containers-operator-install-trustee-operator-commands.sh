#!/usr/bin/env bash

set -euo pipefail

cat <<EOF
>>> Install trustee operator and operands using pre-rendered manifests [$(date -u || true)].
* Use embedded manifests (no network access required)
* Derive the cluster domain
* Generate and apply trustee-operator manifests with runtime substitution
* Wait for the operator to be ready
* Generate and apply trustee-operands manifests with runtime substitution
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
    echo "Failed to install trustee operator"
    echo ">>> Checking trustee operator namespace status"
    oc get all -n "${TRUSTEE_NAMESPACE}" || true
    echo ">>> Checking trustee operator pod logs"
    oc logs -n "${TRUSTEE_NAMESPACE}" -l control-plane=controller-manager --tail=50 || true
  else
    echo "Successfully installed trustee operator"
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
  echo ">>> Deriving cluster domain" >&2
  local cluster_domain=""

  # Method 1: Try to get domain from ingress config (most reliable)
  cluster_domain=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null || true)

  # Method 2: If that fails, try getting it from a console route
  if [[ -z "${cluster_domain}" ]]; then
    echo ">>> Trying alternative method to get cluster domain" >&2
    cluster_domain=$(oc get route -n openshift-console console -o jsonpath='{.spec.host}' 2>/dev/null | sed 's/^console-openshift-console\.//' || true)
  fi

  # Method 3: If that fails, try parsing from cluster console URL
  if [[ -z "${cluster_domain}" ]]; then
    echo ">>> Trying to derive from console URL" >&2
    local console_url
    console_url=$(oc whoami --show-console 2>/dev/null || true)
    if [[ -n "${console_url}" ]]; then
      cluster_domain=$(echo "${console_url}" | sed 's|https://console-openshift-console\.||' | sed 's|/.*||')
    fi
  fi

  if [[ -z "${cluster_domain}" ]]; then
    echo "ERROR: Failed to derive cluster domain" >&2
    return 1
  fi

  echo ">>> Cluster domain: ${cluster_domain}" >&2
  echo "${cluster_domain}"
}

function get_trustee_operator_manifests() {
  cat << 'MANIFEST_EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: TRUSTEE_NAMESPACE_PLACEHOLDER
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: trustee-operator-dev-catalog
  namespace: openshift-marketplace
spec:
  displayName: Trustee Operator Dev Catalog
  sourceType: grpc
  image: "TRUSTEE_IMAGE_PLACEHOLDER"
  publisher: Confidential Containers Team
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: trustee-registry
spec:
  imageDigestMirrors:
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee
      source: registry.redhat.io/confidential-compute-attestation-tech-preview/trustee-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee-operator
      source: registry.redhat.io/confidential-compute-attestation-tech-preview/trustee-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee-operator-bundle
      source: registry.redhat.io/confidential-compute-attestation-tech-preview/trustee-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee
      source: registry.redhat.io/build-of-trustee/trustee-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee-operator
      source: registry.redhat.io/build-of-trustee/trustee-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee-operator-bundle
      source: registry.redhat.io/build-of-trustee/trustee-operator-bundle
---
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: trustee-registry
spec:
  imageTagMirrors:
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee
      source: registry.redhat.io/confidential-compute-attestation-tech-preview/trustee-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee-operator
      source: registry.redhat.io/confidential-compute-attestation-tech-preview/trustee-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee-operator-bundle
      source: registry.redhat.io/confidential-compute-attestation-tech-preview/trustee-operator-bundle
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee
      source: registry.redhat.io/build-of-trustee/trustee-rhel9
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee-operator
      source: registry.redhat.io/build-of-trustee/trustee-rhel9-operator
    - mirrors:
        - quay.io/redhat-user-workloads/ose-osc-tenant/trustee/trustee-operator-bundle
      source: registry.redhat.io/build-of-trustee/trustee-operator-bundle
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: trustee-operator-group
  namespace: TRUSTEE_NAMESPACE_PLACEHOLDER
spec:
  targetNamespaces:
  - TRUSTEE_NAMESPACE_PLACEHOLDER
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: trustee-operator
  namespace: TRUSTEE_NAMESPACE_PLACEHOLDER
spec:
  channel: stable
  installPlanApproval: Automatic
  name: trustee-operator
  source: trustee-operator-dev-catalog
  sourceNamespace: openshift-marketplace
MANIFEST_EOF
}

function get_trustee_operands_manifests() {
  cat << 'MANIFEST_EOF'
---
apiVersion: v1
kind: Secret
metadata:
  name: cosign-keys
  namespace: TRUSTEE_NAMESPACE_PLACEHOLDER
type: Opaque
stringData:
  key-0: |
    -----BEGIN PUBLIC KEY-----
    MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEwQEjdCiL3ILUf07NDkDVhgKCj1C6
    BsCfmM/zt1kNSj0/+nAqA+25XfyClYq2lJFJ6TkgCsf57cTCkXYDz9c+Yg==
    -----END PUBLIC KEY-----
---
apiVersion: v1
kind: Secret
metadata:
  name: containers-policy
  namespace: TRUSTEE_NAMESPACE_PLACEHOLDER
type: Opaque
stringData:
  insecure: |
    {
      "default": [
        {
          "type": "insecureAcceptAnything"
        }
      ],
      "transports": {}
    }
  reject: |
    {
      "default": [
        {
          "type": "reject"
        }
      ],
      "transports": {}
    }
  signed: |
    {
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
    }
---
apiVersion: confidentialcontainers.org/v1alpha1
kind: KbsConfig
metadata:
  name: trustee-operands-kbs-config
  namespace: TRUSTEE_NAMESPACE_PLACEHOLDER
spec:
  kbsSecretResources:
    - containers-policy
    - cosign-keys
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: kbs-service
  namespace: TRUSTEE_NAMESPACE_PLACEHOLDER
spec:
  to:
    kind: Service
    name: kbs-service
  port:
    targetPort: kbs-port
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Allow
---
apiVersion: confidentialcontainers.org/v1alpha1
kind: TrusteeConfig
metadata:
  name: trustee-operands
  namespace: TRUSTEE_NAMESPACE_PLACEHOLDER
spec:
  profileType: Permissive
  kbsServiceType: ClusterIP
MANIFEST_EOF
}

function install_trustee_operator() {
  echo ">>> Creating namespace and applying trustee operator manifests"
  echo ">>> Using image: ${TRUSTEE_IMAGE_REPO}:${TRUSTEE_IMAGE_TAG}"

  get_trustee_operator_manifests | \
    sed "s@TRUSTEE_NAMESPACE_PLACEHOLDER@${TRUSTEE_NAMESPACE}@g" | \
    sed "s@TRUSTEE_IMAGE_PLACEHOLDER@${TRUSTEE_IMAGE_REPO}:${TRUSTEE_IMAGE_TAG}@g" | \
    oc apply -f -
}

function wait_for_operator() {
  echo ">>> Waiting for trustee operator to be ready"

  # Poll for operator deployment to be ready (10 tries, 15s apart = 150s total)
  local deployment_ready=false
  for i in {1..10}; do
    echo ">>> Attempt ${i}/10: Checking operator deployment status"

    if oc get deployment -n "${TRUSTEE_NAMESPACE}" -l control-plane=controller-manager -o jsonpath='{.items[0].status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
      echo ">>> Trustee operator deployment is Available"
      deployment_ready=true
      break
    fi

    # Show current status
    echo ">>> Current deployment status:"
    oc get deployment -n "${TRUSTEE_NAMESPACE}" -l control-plane=controller-manager -o jsonpath='{.items[0].status}' 2>/dev/null || echo "Deployment not found yet"

    if [[ ${i} -lt 10 ]]; then
      echo ">>> Waiting 15 seconds before retry..."
      sleep 15
    fi
  done

  if [[ "${deployment_ready}" != "true" ]]; then
    echo ">>> ERROR: Operator deployment failed to become ready after 10 attempts (150s)"
    echo ">>> Final deployment status:"
    oc get deployment -n "${TRUSTEE_NAMESPACE}" || true
    echo ">>> Pod status:"
    oc get pods -n "${TRUSTEE_NAMESPACE}" || true
    echo ">>> Pod describe:"
    oc describe pods -n "${TRUSTEE_NAMESPACE}" -l control-plane=controller-manager || true
    return 1
  fi

  echo ">>> Trustee operator is ready"
  oc get all -n "${TRUSTEE_NAMESPACE}"
}

function install_trustee_operands() {
  echo ">>> Installing trustee operands"
  echo ">>> Applying trustee operands manifests"
  echo ">>> Using cluster domain: ${CLUSTER_DOMAIN}"

  get_trustee_operands_manifests | \
    sed "s@TRUSTEE_NAMESPACE_PLACEHOLDER@${TRUSTEE_NAMESPACE}@g" | \
    sed "s@CLUSTER_DOMAIN_PLACEHOLDER@${CLUSTER_DOMAIN}@g" | \
    oc apply -f -

  echo ">>> Trustee operands manifests applied"
}

function wait_for_operands() {
  echo ">>> Waiting for trustee operands to be ready"

  # Give some time for operands to be created
  sleep 10

  # Get operand deployments (exclude operator controller)
  local operand_deployments
  operand_deployments=$(oc get deployment -n "${TRUSTEE_NAMESPACE}" -o name 2>/dev/null | grep -v controller-manager || true)

  if [[ -n "${operand_deployments}" ]]; then
    for deployment in ${operand_deployments}; do
      echo ">>> Waiting for ${deployment} to be ready"

      # Poll for deployment to be ready (10 tries, 15s apart = 150s total)
      local deployment_ready=false
      for i in {1..10}; do
        echo ">>> Attempt ${i}/10: Checking ${deployment} status"

        if oc get "${deployment}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null | grep -q "True"; then
          echo ">>> ${deployment} is Available"
          deployment_ready=true
          break
        fi

        # Show current status
        echo ">>> Current status:"
        oc get "${deployment}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.status}' 2>/dev/null || echo "Deployment status unavailable"

        if [[ ${i} -lt 10 ]]; then
          echo ">>> Waiting 15 seconds before retry..."
          sleep 15
        fi
      done

      if [[ "${deployment_ready}" != "true" ]]; then
        echo ">>> WARNING: ${deployment} failed to become ready after 10 attempts (150s)"
        echo ">>> Final status:"
        oc get "${deployment}" -n "${TRUSTEE_NAMESPACE}" || true
        oc describe "${deployment}" -n "${TRUSTEE_NAMESPACE}" || true
        # Continue checking other deployments instead of failing immediately
      fi
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
      # Use HTTP for test environments to avoid self-signed certificate issues
      # The route has insecureEdgeTerminationPolicy: Allow which permits HTTP
      # Production CoCo workloads will use the certificate embedded in INITDATA
      trustee_url="http://${trustee_host}"
      echo ">>> Found OpenShift route: ${trustee_url}"
      echo ">>> Using HTTP to avoid self-signed certificate issues in test environment"
    fi
  fi

  # Method 2: Try LoadBalancer service
  if [[ -z "${trustee_url}" ]]; then
    local trustee_ip
    trustee_ip=$(oc get svc "${kbs_service}" -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    if [[ -z "${trustee_ip}" ]]; then
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

  # Save Trustee URL, host, and port to shared directory
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

function verify_trustee_connectivity() {
  echo ">>> Verifying Trustee connectivity using kbs-client"

  local kbs_client_pod="kbs-client-test"
  local kbs_client_namespace="$TRUSTEE_NAMESPACE"
  local kbs_client_image="quay.io/confidential-containers/kbs-client:v0.17.0"

  # Create kbs-client pod
  echo ">>> Creating kbs-client pod"
  get_kbs_client_manifest | \
    sed "s@KBS_CLIENT_POD_PLACEHOLDER@${kbs_client_pod}@g" | \
    sed "s@KBS_CLIENT_NAMESPACE_PLACEHOLDER@${kbs_client_namespace}@g" | \
    sed "s@KBS_CLIENT_IMAGE_PLACEHOLDER@${kbs_client_image}@g" | \
    oc apply -f -

  # Poll for pod to be ready (10 tries, 15s apart = 150s total)
  echo ">>> Waiting for kbs-client pod to be ready"
  local pod_ready=false
  for i in {1..10}; do
    echo ">>> Attempt ${i}/10: Checking kbs-client pod status"

    if oc get pod/${kbs_client_pod} -n ${kbs_client_namespace} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
      echo ">>> kbs-client pod is Ready"
      pod_ready=true
      break
    fi

    # Show current status
    echo ">>> Current pod phase:"
    oc get pod/${kbs_client_pod} -n ${kbs_client_namespace} -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pod not found yet"
    echo ">>> Current pod conditions:"
    oc get pod/${kbs_client_pod} -n ${kbs_client_namespace} -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || true

    if [[ ${i} -lt 10 ]]; then
      echo ">>> Waiting 15 seconds before retry..."
      sleep 15
    fi
  done

  if [[ "${pod_ready}" != "true" ]]; then
    echo ">>> ERROR: kbs-client pod failed to become ready after 10 attempts (150s)"
    echo ">>> Pod describe:"
    oc describe pod/${kbs_client_pod} -n ${kbs_client_namespace} || true
    echo ">>> Pod logs:"
    oc logs pod/${kbs_client_pod} -n ${kbs_client_namespace} || true
    oc delete pod/${kbs_client_pod} -n ${kbs_client_namespace} --ignore-not-found=true
    return 1
  fi

  echo ">>> kbs-client pod is ready"

  # Test basic connectivity to Trustee KBS
  echo ">>> Testing connectivity to Trustee KBS at ${TRUSTEE_URL}"
  echo ">>> Using HTTP to avoid certificate issues in test environment"

  local kbs_test_failed=false

  # Try to fetch a resource (basic connectivity test using HTTP)
  if oc exec ${kbs_client_pod} -n ${kbs_client_namespace} -- \
    kbs-client --url "${TRUSTEE_URL}" get-resource --path default/kbsres1/key1 2>&1 | tee /tmp/kbs-test-output.txt; then
    echo ">>> SUCCESS: Successfully connected to Trustee KBS and retrieved resource"
    kbs_test_failed=false
  elif grep -q "404\|not found\|NotFound" /tmp/kbs-test-output.txt; then
    echo ">>> SUCCESS: Trustee KBS is responding (404 for test resource is expected)"
    echo ">>> This confirms KBS connectivity is working correctly"
    kbs_test_failed=false
  else
    # Connection failed
    echo ">>> ERROR: Failed to connect to Trustee KBS"
    echo ">>> kbs-client must be able to connect to KBS service"
    cat /tmp/kbs-test-output.txt || true

    # Check for specific error patterns
    if grep -q "timed out\|Connection timed out" /tmp/kbs-test-output.txt; then
      echo ">>> ERROR: Connection timeout - KBS service may not be accessible"
    fi
    if grep -q "certificate verify failed\|SSL\|TLS" /tmp/kbs-test-output.txt; then
      echo ">>> ERROR: SSL/TLS error - URL should be HTTP, not HTTPS"
      echo ">>> Current TRUSTEE_URL: ${TRUSTEE_URL}"
    fi

    kbs_test_failed=true
  fi

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

    # Also save to SHARED_DIR if ARTIFACT_DIR is different
    if [[ -n "${ARTIFACT_DIR}" && "${ARTIFACT_DIR}" != "${SHARED_DIR}" ]]; then
      cp "${log_file}" "${SHARED_DIR}/kbs-attestation-logs.txt" 2>/dev/null || true
    fi

    # Show relevant attestation log entries
    echo ">>> KBS attestation log summary:"
    echo "================================================"
    grep -E "attest|resource|POST|GET|kbs/v0" "${log_file}" 2>/dev/null | tail -30 || \
      echo ">>> No attestation-related logs found (may be using different log format)"
    echo "================================================"

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

  # Fail the step if kbs-client could not connect
  if [[ "${kbs_test_failed}" == "true" ]]; then
    echo ">>> FAILED: kbs-client connectivity test failed"
    echo ">>> The Trustee KBS service must be accessible for CoCo workloads to function"
    return 1
  fi

  echo ">>> SUCCESS: Trustee connectivity verification completed"
  return 0
}

echo ">>> Begin trustee operator installation"

# Get cluster domain
CLUSTER_DOMAIN=$(get_cluster_domain)
export CLUSTER_DOMAIN
echo "CLUSTER_DOMAIN=${CLUSTER_DOMAIN}"

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
