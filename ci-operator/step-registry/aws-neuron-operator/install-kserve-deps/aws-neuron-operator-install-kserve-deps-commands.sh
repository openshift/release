#!/bin/bash

set -o nounset
set -o pipefail

echo "Installing KServe inference stack dependencies"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

OCP_MINOR=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d. -f2)
echo "Detected OCP minor version: 4.${OCP_MINOR}"

if [[ "${OCP_MINOR}" -ge 21 ]]; then
    KSERVE_MODE="RawDeployment"
    if [[ "${RHOAI_CHANNEL}" != stable-3.* ]]; then
        echo "OCP >= 4.21 requires RHOAI 3.x; overriding RHOAI_CHANNEL from '${RHOAI_CHANNEL}' to 'stable-3.x'"
        RHOAI_CHANNEL="stable-3.x"
    fi
else
    KSERVE_MODE="Serverless"
fi
echo "Using KServe deployment mode: ${KSERVE_MODE} (RHOAI channel: ${RHOAI_CHANNEL})"

approve_install_plans() {
    local ns="${1}"
    local sub_name="${2}"
    local csv_name
    csv_name=$(oc get sub "${sub_name}" -n "${ns}" -o jsonpath='{.status.currentCSV}' 2>/dev/null)
    if [[ -z "${csv_name}" ]]; then
        return
    fi
    oc get installplan -n "${ns}" -o json 2>/dev/null \
        | jq -r ".items[] | select(.spec.approved == false)
                  | select(.spec.clusterServiceVersionNames[]? == \"${csv_name}\")
                  | .metadata.name" \
        | while read -r plan; do
            echo "Auto-approving InstallPlan '${plan}' for ${csv_name} in ${ns}"
            oc patch installplan "${plan}" -n "${ns}" --type=merge -p '{"spec":{"approved":true}}'
        done
}

wait_for_csv() {
    local ns="${1}"
    local name_prefix="${2}"
    local timeout="${3:-600}"
    local sub_name="${4:-}"
    local elapsed=0

    echo "Waiting for CSV starting with '${name_prefix}' in namespace '${ns}' to reach Succeeded..."
    while [[ ${elapsed} -lt ${timeout} ]]; do
        if [[ -n "${sub_name}" ]]; then
            approve_install_plans "${ns}" "${sub_name}"
        fi
        local phase
        phase=$(oc get csv -n "${ns}" -o json 2>/dev/null \
            | jq -r ".items[] | select(.metadata.name | startswith(\"${name_prefix}\")) | .status.phase" \
            | head -1)
        if [[ "${phase}" == "Succeeded" ]]; then
            echo "CSV '${name_prefix}' reached Succeeded in ${elapsed}s"
            return 0
        fi
        sleep 15
        elapsed=$((elapsed + 15))
    done
    echo "ERROR: CSV '${name_prefix}' did not reach Succeeded within ${timeout}s (last phase: ${phase:-unknown})"
    oc get csv -n "${ns}" -o wide 2>/dev/null || true
    return 1
}

# Service Mesh and Serverless are only needed for Serverless mode (OCP < 4.21).
# OCP 4.21+ deprecates Service Mesh 2.x; KServe uses RawDeployment instead.
if [[ "${KSERVE_MODE}" == "Serverless" ]]; then
    # --- 1. Install Service Mesh operator ---
    echo "=== Installing Service Mesh operator ==="
    oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: servicemeshoperator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    # --- 2. Install Serverless operator ---
    echo "=== Installing Serverless operator ==="
    oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-serverless
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-serverless
  namespace: openshift-serverless
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: openshift-serverless
spec:
  channel: stable
  installPlanApproval: Automatic
  name: serverless-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
fi

# --- 3. Install RHOAI operator ---
# RHOAI 3.x only supports AllNamespaces install mode, so it must be installed
# in openshift-operators (which has a global OperatorGroup). RHOAI 2.x supports
# OwnNamespace and can use a dedicated namespace.
echo "=== Installing OpenShift AI (RHOAI) operator ==="
if [[ "${KSERVE_MODE}" == "RawDeployment" ]]; then
    RHOAI_NAMESPACE="openshift-operators"
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: ${RHOAI_NAMESPACE}
spec:
  channel: ${RHOAI_CHANNEL}
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
else
    RHOAI_NAMESPACE="redhat-ods-operator"
    oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${RHOAI_NAMESPACE}
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: ${RHOAI_NAMESPACE}
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: ${RHOAI_NAMESPACE}
spec:
  channel: ${RHOAI_CHANNEL}
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
fi

# --- 4. Wait for all CSVs ---
echo "=== Waiting for operator CSVs ==="
if [[ "${KSERVE_MODE}" == "Serverless" ]]; then
    wait_for_csv "openshift-operators" "servicemeshoperator" 600 "servicemeshoperator" || exit 1
    wait_for_csv "openshift-serverless" "serverless-operator" 600 "serverless-operator" || exit 1
fi
wait_for_csv "${RHOAI_NAMESPACE}" "rhods-operator" 600 "rhods-operator" || exit 1
echo "All operator CSVs reached Succeeded"

# --- 5. Configure DSCI for RawDeployment (disable Service Mesh on RHOAI 2.x) ---
if [[ "${KSERVE_MODE}" == "RawDeployment" ]]; then
    echo "=== Configuring DSCI for RawDeployment mode ==="
    DSCI_TIMEOUT=300
    DSCI_ELAPSED=0
    while [[ ${DSCI_ELAPSED} -lt ${DSCI_TIMEOUT} ]]; do
        DSCI_NAME=$(oc get dsci -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "${DSCI_NAME}" ]]; then
            break
        fi
        sleep 10
        DSCI_ELAPSED=$((DSCI_ELAPSED + 10))
    done
    if [[ ${DSCI_ELAPSED} -ge ${DSCI_TIMEOUT} ]]; then
        echo "ERROR: DSCI not found within ${DSCI_TIMEOUT}s"
        exit 1
    fi
    # RHOAI 3.x (DSCI apiVersion v2) removed spec.serviceMesh entirely.
    # Only patch on RHOAI 2.x where the field still exists.
    DSCI_API=$(oc get dsci "${DSCI_NAME}" -o jsonpath='{.apiVersion}' 2>/dev/null)
    if [[ "${DSCI_API}" != *"/v2" ]]; then
        oc patch dsci "${DSCI_NAME}" --type=merge \
            -p '{"spec":{"serviceMesh":{"managementState":"Removed"}}}'
        echo "DSCI '${DSCI_NAME}' patched: serviceMesh set to Removed"
    else
        echo "DSCI '${DSCI_NAME}' uses ${DSCI_API} (RHOAI 3.x) -- serviceMesh field not present, skipping patch"
    fi
fi

# --- 6. Create DataScienceCluster ---
echo "=== Creating DataScienceCluster ==="
if [[ "${KSERVE_MODE}" == "Serverless" ]]; then
    oc apply -f - <<'EOF'
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    codeflare:
      managementState: Removed
    dashboard:
      managementState: Managed
    datasciencepipelines:
      managementState: Removed
    kserve:
      managementState: Managed
      serving:
        ingressGateway:
          certificate:
            type: SelfSigned
        managementState: Managed
    kueue:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    modelregistry:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Removed
    workbenches:
      managementState: Removed
EOF
else
    oc apply -f - <<'EOF'
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    codeflare:
      managementState: Removed
    dashboard:
      managementState: Managed
    datasciencepipelines:
      managementState: Removed
    kserve:
      managementState: Managed
      serving:
        managementState: Removed
    kueue:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    modelregistry:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Removed
    workbenches:
      managementState: Removed
EOF
fi

echo "Waiting for DataScienceCluster to reach Ready..."
oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster/default-dsc --timeout=600s || {
    echo "ERROR: DataScienceCluster did not reach Ready"
    oc get datasciencecluster default-dsc -o yaml 2>/dev/null || true
    exit 1
}
echo "DataScienceCluster is Ready"

# --- 7. Configure inference namespace ---
echo "=== Configuring inference namespace ==="
oc create namespace "${KSERVE_INFERENCE_NAMESPACE}" 2>/dev/null || true
if [[ "${KSERVE_MODE}" == "Serverless" ]]; then
    oc label namespace "${KSERVE_INFERENCE_NAMESPACE}" istio-injection=enabled --overwrite
fi

# --- 8. Patch Knative Serving config (Serverless mode only) ---
if [[ "${KSERVE_MODE}" == "Serverless" ]]; then
    echo "=== Patching Knative Serving config ==="
    KNATIVE_TIMEOUT=300
    KNATIVE_ELAPSED=0
    while [[ ${KNATIVE_ELAPSED} -lt ${KNATIVE_TIMEOUT} ]]; do
        if oc get configmap config-deployment -n knative-serving &>/dev/null; then
            if oc patch configmap config-deployment -n knative-serving --type=merge \
                -p '{"data":{"registries-skipping-tag-resolving":"kind.local,ko.local,dev.local,registry.redhat.io"}}'; then
                echo "Knative Serving config-deployment patched"
                break
            fi
        fi
        sleep 10
        KNATIVE_ELAPSED=$((KNATIVE_ELAPSED + 10))
    done
    if [[ ${KNATIVE_ELAPSED} -ge ${KNATIVE_TIMEOUT} ]]; then
        echo "ERROR: knative-serving/config-deployment configmap could not be patched within ${KNATIVE_TIMEOUT}s"
        exit 1
    fi
fi

# --- 9. Create ServingRuntime ---
echo "=== Creating vllm-neuron ServingRuntime ==="
oc apply -f - <<EOF
apiVersion: serving.kserve.io/v1alpha1
kind: ServingRuntime
metadata:
  name: vllm-neuron-runtime
  namespace: ${KSERVE_INFERENCE_NAMESPACE}
  annotations:
    openshift.io/display-name: "vLLM for AWS Neuron"
    opendatahub.io/recommended-accelerators: '["neuron.amazonaws.com"]'
$(if [[ "${KSERVE_MODE}" == "Serverless" ]]; then
    echo '    sidecar.istio.io/inject: "true"'
    echo '    serving.knative.openshift.io/enablePassthrough: "true"'
fi)
spec:
  multiModel: false
  supportedModelFormats:
  - autoSelect: true
    name: vllm-neuron
  containers:
  - name: kserve-container
    image: ${VLLM_NEURON_IMAGE}
    command:
    - python3
    - -m
    - vllm.entrypoints.openai.api_server
    args:
    - --port=8080
    - --model=/mnt/models
    - --served-model-name={{.Name}}
    - --tensor-parallel-size=${TENSOR_PARALLEL_SIZE}
    - --max-num-seqs=${MAX_NUM_SEQS}
    - --max-model-len=${MAX_MODEL_LEN}
    - --disable-frontend-multiprocessing
    - --no-enable-chunked-prefill
    - --no-enable-prefix-caching
    env:
    - name: NEURON_COMPILE_CACHE_URL
      value: /mnt/models/neuron-compiled-artifacts
    ports:
    - containerPort: 8080
      protocol: TCP
    readinessProbe:
      httpGet:
        path: /health
        port: 8080
      initialDelaySeconds: 900
      periodSeconds: 10
    livenessProbe:
      httpGet:
        path: /health
        port: 8080
      initialDelaySeconds: 900
      periodSeconds: 10
    volumeMounts:
    - name: shm
      mountPath: /dev/shm
    - name: neuron-compile
      mountPath: /mnt/models/neuron-compiled-artifacts
  volumes:
  - name: shm
    emptyDir:
      medium: Memory
      sizeLimit: 2Gi
  - name: neuron-compile
    emptyDir: {}
EOF

# --- 10. Create HF token secret and ServiceAccount ---
echo "=== Setting up model access credentials ==="
if [[ -f "${CLUSTER_PROFILE_DIR}/hf-token" ]]; then
    HF_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/hf-token")
    oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: hf-token
  namespace: ${KSERVE_INFERENCE_NAMESPACE}
type: Opaque
stringData:
  HF_TOKEN: ${HF_TOKEN}
EOF
    echo "HF token secret created"
else
    echo "WARNING: No HF token found at ${CLUSTER_PROFILE_DIR}/hf-token"
fi

oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kserve-neuron-sa
  namespace: ${KSERVE_INFERENCE_NAMESPACE}
secrets:
- name: hf-token
EOF

echo "KServe inference stack installation complete (mode: ${KSERVE_MODE})"
