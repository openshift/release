#!/bin/bash

set -o nounset
set -o pipefail

echo "Installing KServe inference stack dependencies"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

wait_for_csv() {
    local ns="${1}"
    local name_prefix="${2}"
    local timeout="${3:-600}"
    local elapsed=0

    echo "Waiting for CSV starting with '${name_prefix}' in namespace '${ns}' to reach Succeeded..."
    while [[ ${elapsed} -lt ${timeout} ]]; do
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

# --- 3. Install RHOAI operator ---
echo "=== Installing OpenShift AI (RHOAI) operator ==="
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: ${RHOAI_CHANNEL}
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# --- 4. Wait for all CSVs ---
echo "=== Waiting for operator CSVs ==="
wait_for_csv "openshift-operators" "servicemeshoperator" 600 || exit 1
wait_for_csv "openshift-serverless" "serverless-operator" 600 || exit 1
wait_for_csv "redhat-ods-operator" "rhods-operator" 600 || exit 1
echo "All operator CSVs reached Succeeded"

# --- 5. Create DataScienceCluster ---
echo "=== Creating DataScienceCluster ==="
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

echo "Waiting for DataScienceCluster to reach Ready..."
oc wait --for=jsonpath='{.status.phase}'=Ready datasciencecluster/default-dsc --timeout=600s || {
    echo "ERROR: DataScienceCluster did not reach Ready"
    oc get datasciencecluster default-dsc -o yaml 2>/dev/null || true
    exit 1
}
echo "DataScienceCluster is Ready"

# --- 6. Configure inference namespace ---
echo "=== Configuring inference namespace ==="
oc create namespace "${KSERVE_INFERENCE_NAMESPACE}" 2>/dev/null || true
oc label namespace "${KSERVE_INFERENCE_NAMESPACE}" istio-injection=enabled --overwrite

# --- 7. Patch Knative Serving config ---
echo "=== Patching Knative Serving config ==="
KNATIVE_TIMEOUT=300
KNATIVE_ELAPSED=0
while [[ ${KNATIVE_ELAPSED} -lt ${KNATIVE_TIMEOUT} ]]; do
    if oc get configmap config-deployment -n knative-serving &>/dev/null; then
        oc patch configmap config-deployment -n knative-serving --type=merge \
            -p '{"data":{"registries-skipping-tag-resolving":"kind.local,ko.local,dev.local,registry.redhat.io"}}' || true
        echo "Knative Serving config-deployment patched"
        break
    fi
    sleep 10
    KNATIVE_ELAPSED=$((KNATIVE_ELAPSED + 10))
done
if [[ ${KNATIVE_ELAPSED} -ge ${KNATIVE_TIMEOUT} ]]; then
    echo "WARNING: knative-serving/config-deployment configmap not found within ${KNATIVE_TIMEOUT}s"
fi

# --- 8. Create ServingRuntime ---
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
    sidecar.istio.io/inject: "true"
    serving.knative.openshift.io/enablePassthrough: "true"
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
    - --enable-chunked-prefill=false
    - --enable-prefix-caching=false
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

# --- 9. Create HF token secret and ServiceAccount ---
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

echo "KServe inference stack installation complete"
