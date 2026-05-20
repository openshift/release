#!/usr/bin/env bash

set -euo pipefail

export SHARED_DIR=${SHARED_DIR:-/tmp}
export KUBECONFIG=${KUBECONFIG:-${SHARED_DIR}/kubeconfig}
TRUSTEE_INSTALL=${TRUSTEE_INSTALL:-false}

if [[ "${TRUSTEE_INSTALL}" != "true" ]]; then
  echo ">>> Skipping trustee operator installation (TRUSTEE_INSTALL=${TRUSTEE_INSTALL})"
  exit 0
fi

TRUSTEE_NAMESPACE=${TRUSTEE_NAMESPACE:-trustee-operator-system}
TRUSTEE_CATALOG_SOURCE_NAME=${TRUSTEE_CATALOG_SOURCE_NAME:-redhat-operators}
TRUSTEE_CATALOG_SOURCE_IMAGE=${TRUSTEE_CATALOG_SOURCE_IMAGE:-}

# Legacy variables for backward compatibility (used when TRUSTEE_CATALOG_SOURCE_IMAGE is set)
TRUSTEE_IMAGE_REPO=${TRUSTEE_IMAGE_REPO:-quay.io/redhat-user-workloads/ose-osc-tenant/trustee-test-fbc}
TRUSTEE_IMAGE_TAG=${TRUSTEE_IMAGE_TAG:-1.1.0-1776506656}

if [[ -n "${TRUSTEE_CATALOG_SOURCE_IMAGE}" ]]; then
  echo ">>> Trustee catalog source: ${TRUSTEE_CATALOG_SOURCE_NAME} (image: ${TRUSTEE_CATALOG_SOURCE_IMAGE})"
else
  echo ">>> Trustee catalog source: ${TRUSTEE_CATALOG_SOURCE_NAME} (using existing catalog)"
fi

SCRATCH=$(mktemp -d)
cd "${SCRATCH}"

function exit_handler() {
  exitcode=$?
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

function retry() {
  "$@" && return 0  # unrolled 1 to simplify sleep only between tries
  for (( i = 0; i < 9; i++ )); do
    sleep 30
    "$@" && return 0
  done
  return 1
}

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

function get_trustee_catalog_source_manifest() {
  # Only output CatalogSource manifest if TRUSTEE_CATALOG_SOURCE_IMAGE is set
  # and the catalog source doesn't already exist
  if [[ -z "${TRUSTEE_CATALOG_SOURCE_IMAGE}" ]]; then
    return 0
  fi

  if oc get catalogsource -n openshift-marketplace "${TRUSTEE_CATALOG_SOURCE_NAME}" &>/dev/null; then
    echo ">>> CatalogSource ${TRUSTEE_CATALOG_SOURCE_NAME} already exists, skipping creation"
    return 0
  fi

  cat << 'CATALOG_EOF'
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: TRUSTEE_CATALOG_SOURCE_NAME_PLACEHOLDER
  namespace: openshift-marketplace
spec:
  displayName: Trustee Operator Catalog
  sourceType: grpc
  image: "TRUSTEE_CATALOG_SOURCE_IMAGE_PLACEHOLDER"
  publisher: Confidential Containers Team
---
CATALOG_EOF
}

function get_trustee_operator_manifests() {
  cat << 'MANIFEST_EOF'
---
apiVersion: v1
kind: Namespace
metadata:
  name: TRUSTEE_NAMESPACE_PLACEHOLDER
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
  source: TRUSTEE_CATALOG_SOURCE_NAME_PLACEHOLDER
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
apiVersion: v1
kind: Secret
metadata:
  name: kbsres1
  namespace: TRUSTEE_NAMESPACE_PLACEHOLDER
type: Opaque
data:
  key1: cmVzMXZhbDEK
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
    - kbsres1
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
  # Apply CatalogSource if needed (only if TRUSTEE_CATALOG_SOURCE_IMAGE is set and catalog doesn't exist)
  get_trustee_catalog_source_manifest | \
    sed "s@TRUSTEE_CATALOG_SOURCE_NAME_PLACEHOLDER@${TRUSTEE_CATALOG_SOURCE_NAME}@g" | \
    sed "s@TRUSTEE_CATALOG_SOURCE_IMAGE_PLACEHOLDER@${TRUSTEE_CATALOG_SOURCE_IMAGE}@g" | \
    oc apply -f - || true

  # Apply operator manifests (Namespace, mirrors, OperatorGroup, Subscription)
  get_trustee_operator_manifests | \
    sed "s@TRUSTEE_NAMESPACE_PLACEHOLDER@${TRUSTEE_NAMESPACE}@g" | \
    sed "s@TRUSTEE_CATALOG_SOURCE_NAME_PLACEHOLDER@${TRUSTEE_CATALOG_SOURCE_NAME}@g" | \
    oc apply -f -
}

function wait_for_operator() {
  # OLM installation stages (poll each with timeout)
  # 1. CatalogSource READY
  # 2. Subscription has InstallPlan
  # 3. InstallPlan Complete
  # 4. CSV Succeeded
  # 5. Deployment Available

  # Stage 1: Wait for CatalogSource to be READY (60s)
  # Skip if using existing catalog (no TRUSTEE_CATALOG_SOURCE_IMAGE provided)
  if [[ -n "${TRUSTEE_CATALOG_SOURCE_IMAGE}" ]]; then
    echo ">>> Waiting for CatalogSource ${TRUSTEE_CATALOG_SOURCE_NAME} to be READY..."
    local catalog_ready=false
    for i in {1..12}; do
      local state=$(oc get catalogsource -n openshift-marketplace "${TRUSTEE_CATALOG_SOURCE_NAME}" -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
      if [[ "${state}" == "READY" ]]; then
        echo ">>> CatalogSource ${TRUSTEE_CATALOG_SOURCE_NAME} is READY"
        catalog_ready=true
        break
      fi
      [[ ${i} -lt 12 ]] && sleep 5
    done

    if [[ "${catalog_ready}" != "true" ]]; then
      echo ">>> ERROR: CatalogSource ${TRUSTEE_CATALOG_SOURCE_NAME} not READY after 60s"
      oc get catalogsource -n openshift-marketplace "${TRUSTEE_CATALOG_SOURCE_NAME}" -o yaml || true
      oc get pods -n openshift-marketplace -l olm.catalogSource="${TRUSTEE_CATALOG_SOURCE_NAME}" || true
      oc describe pods -n openshift-marketplace -l olm.catalogSource="${TRUSTEE_CATALOG_SOURCE_NAME}" | tail -50 || true
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
    local phase=$(oc get installplan -n "${TRUSTEE_NAMESPACE}" "${installplan_ref}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
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
  for i in {1..12}; do
    local csv_phase=$(oc get csv -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "${csv_phase}" == "Succeeded" ]]; then
      local csv_name=$(oc get csv -n "${TRUSTEE_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
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

function install_trustee_operands() {
  echo ">>> Cluster domain: ${CLUSTER_DOMAIN}"

  get_trustee_operands_manifests | \
    sed "s@TRUSTEE_NAMESPACE_PLACEHOLDER@${TRUSTEE_NAMESPACE}@g" | \
    sed "s@CLUSTER_DOMAIN_PLACEHOLDER@${CLUSTER_DOMAIN}@g" | \
    oc apply -f -
}

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

function get_kbs_client_tag() {
  if [[ -n "${KBS_CLIENT_TAG:-}" ]]; then
    echo ">>> kbs-client tag (from KBS_CLIENT_TAG): ${KBS_CLIENT_TAG}" >&2
    echo "${KBS_CLIENT_TAG}"
    return 0
  fi

  local latest_tag=""
  latest_tag=$(skopeo list-tags docker://quay.io/confidential-containers/kbs-client 2>/dev/null | \
    jq -r '.Tags[]' | \
    grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | \
    sort -V | \
    tail -1 || echo "")

  if [[ -n "${latest_tag}" ]]; then
    echo ">>> kbs-client tag (auto-discovered): ${latest_tag}" >&2
    echo "${latest_tag}"
    return 0
  fi

  echo ">>> WARN: Could not determine latest tag, using fallback: v0.19.0" >&2
  echo "v0.19.0"
}

function verify_trustee_connectivity() {
  local kbs_client_pod="kbs-client-test"
  local kbs_client_namespace="$TRUSTEE_NAMESPACE"

  local kbs_client_tag
  kbs_client_tag=$(get_kbs_client_tag)
  local kbs_client_image="quay.io/confidential-containers/kbs-client:${kbs_client_tag}"

  get_kbs_client_manifest | \
    sed "s@KBS_CLIENT_POD_PLACEHOLDER@${kbs_client_pod}@g" | \
    sed "s@KBS_CLIENT_NAMESPACE_PLACEHOLDER@${kbs_client_namespace}@g" | \
    sed "s@KBS_CLIENT_IMAGE_PLACEHOLDER@${kbs_client_image}@g" | \
    oc apply -f -

  # Wait for pod ready (10 tries, 15s apart = 150s total)
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

  local kbs_test_failed=false

  # Test KBS connectivity by retrieving a real resource
  # Note: kbs-client will perform RCA protocol handshake:
  #   1. GET resource → 401 (no token)
  #   2. POST /auth + POST /attest (get attestation token)
  #   3. GET resource → 200 (with token)
  # We suppress normal protocol warnings (stderr) on success
  echo ">>> Testing KBS connectivity at ${TRUSTEE_URL}"
  echo ">>> Running: oc exec ${kbs_client_pod} -n ${kbs_client_namespace} -- kbs-client --url \"${TRUSTEE_URL}\" get-resource --path default/kbsres1/key1"
  if oc exec ${kbs_client_pod} -n ${kbs_client_namespace} -- \
    kbs-client --url "${TRUSTEE_URL}" get-resource --path default/kbsres1/key1 \
    > /tmp/kbs-resource.txt 2> /tmp/kbs-stderr.txt; then

    # Success - show that we got the resource
    echo ">>> Successfully retrieved default/kbsres1/key1"
    local resource_value
    resource_value=$(cat /tmp/kbs-resource.txt 2>/dev/null || echo "")
    echo ">>> Resource value: ${resource_value}"

    kbs_test_failed=false
  else
    # Failed - show full diagnostics
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

  # Capture KBS logs showing attestation attempts
  local kbs_pod
  kbs_pod=$(oc get pod -n "${TRUSTEE_NAMESPACE}" -l app=kbs -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "${kbs_pod}" ]]; then
    local log_file="${ARTIFACT_DIR:-${SHARED_DIR}}/kbs-attestation-logs.txt"
    oc logs "${kbs_pod}" -n "${TRUSTEE_NAMESPACE}" --since=5m > "${log_file}" 2>&1 || true

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

CLUSTER_DOMAIN=$(get_cluster_domain)
export CLUSTER_DOMAIN

install_trustee_operator
wait_for_operator
install_trustee_operands
wait_for_operands
get_trustee_url
create_initdata
update_env_configmap
verify_trustee_connectivity
