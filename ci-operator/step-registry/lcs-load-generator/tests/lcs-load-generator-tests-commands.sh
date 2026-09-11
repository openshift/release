#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# LCS Load Generator — CI Orchestration Script
#
# This script is the CI step command for lcs-load-generator performance tests.
# It deploys lightspeed-core (library mode) with a mock LLM sidecar,
# runs the lcs-load-generator K8s Job, collects profiling data, and
# copies artifacts to ${ARTIFACT_DIR}.
#
# The load generator itself runs as a K8s Job (not from this pod).
# This script orchestrates the environment, then applies the Job manifest.
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ─── 1. CONFIGURATION ────────────────────────────────────────────────────────

LCS_NAMESPACE="${LCS_NAMESPACE:-openshift-lightspeed}"
NUM_USERS="${NUM_USERS:-5}"
TEST_DURATION="${TEST_DURATION:-5m}"
LCS_LOADGEN_IMAGE="${LCS_LOADGEN_IMAGE:-quay.io/rh-ee-bbodapat/lcs-load-generator:latest}"
LCS_APP_IMAGE="${LCS_APP_IMAGE:-quay.io/redhat-et/lightspeed-stack:dev-latest}"
MOCK_LLM_IMAGE="${MOCK_LLM_IMAGE:-quay.io/rh-ee-bbodapat/lcs-testing:mock-llm-server}"
ENABLE_PYROSCOPE="${ENABLE_PYROSCOPE:-true}"
ENABLE_MEMRAY="${ENABLE_MEMRAY:-false}"
LCS_WORKERS="${LCS_WORKERS:-1}"
ES_INDEX="${ES_INDEX:-lcs-perf-results}"

LCS_PROVIDER="${LCS_PROVIDER:-openai}"
LCS_MODEL="${LCS_MODEL:-granite-3.1-8b-instruct}"
LCS_HOST="http://lcs-service.${LCS_NAMESPACE}.svc.cluster.local:8080"
LCS_TOKEN=""
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-120}"
LOCUST_PROCESSES="${LOCUST_PROCESSES:-1}"
METRIC_STEP="${METRIC_STEP:-30s}"

PYROSCOPE_NAMESPACE="pyroscope"
PYROSCOPE_URL="http://pyroscope.${PYROSCOPE_NAMESPACE}.svc.cluster.local:4040"

# ─── Read ES credentials ───
ES_PASSWORD=$(<"/secret/password")
ES_USERNAME=$(<"/secret/username")
ES_SERVER_HOST="${ES_SERVER_HOST:-search-ocp-qe-perf-scale-test}"
ES_SERVER="https://${ES_USERNAME}:${ES_PASSWORD}@${ES_SERVER_HOST}"

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  LCS Performance Test Configuration                     ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Namespace:       ${LCS_NAMESPACE}"
echo "║  Users:           ${NUM_USERS}"
echo "║  Duration:        ${TEST_DURATION}"
echo "║  LCS Image:       ${LCS_APP_IMAGE}"
echo "║  LoadGen Image:   ${LCS_LOADGEN_IMAGE}"
echo "║  Workers:         ${LCS_WORKERS}"
echo "║  Pyroscope:       ${ENABLE_PYROSCOPE}"
echo "║  Memray:          ${ENABLE_MEMRAY}"
echo "║  ES Index:        ${ES_INDEX}"
echo "╚══════════════════════════════════════════════════════════╝"


# ─── 2. CREATE NAMESPACE & MONITORING PREREQUISITES ──────────────────────────

echo "── Creating namespace ${LCS_NAMESPACE} ──"
oc create namespace "${LCS_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# Required for platform Prometheus to scrape ServiceMonitor in openshift-* ns
oc label namespace "${LCS_NAMESPACE}" openshift.io/cluster-monitoring=true --overwrite

# RBAC for Prometheus to scrape pods in this namespace
cat <<'PROM_RBAC' | envsubst | oc apply -f -
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prometheus-k8s
  namespace: ${LCS_NAMESPACE}
rules:
  - apiGroups: [""]
    resources: ["services", "endpoints", "pods"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: prometheus-k8s
  namespace: ${LCS_NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: prometheus-k8s
subjects:
  - kind: ServiceAccount
    name: prometheus-k8s
    namespace: openshift-monitoring
PROM_RBAC

# ServiceMonitor for LCS metrics
cat <<'SVCMON' | envsubst | oc apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: lcs-monitor
  namespace: ${LCS_NAMESPACE}
spec:
  selector:
    matchLabels:
      app: lcs
  endpoints:
    - targetPort: 8080
      path: /metrics
      interval: 30s
SVCMON

echo "── Namespace and monitoring ready ──"


# ─── 3. DEPLOY PYROSCOPE (if enabled) ───────────────────────────────────────

if [[ "${ENABLE_PYROSCOPE}" == "true" ]]; then
  echo "── Deploying Pyroscope ──"
  oc create namespace "${PYROSCOPE_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

  cat <<'PYROSCOPE' | envsubst | oc apply -f -
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pyroscope
  namespace: ${PYROSCOPE_NAMESPACE}
  labels:
    app: pyroscope
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pyroscope
  template:
    metadata:
      labels:
        app: pyroscope
    spec:
      containers:
        - name: pyroscope
          image: grafana/pyroscope:latest
          ports:
            - containerPort: 4040
          resources:
            requests:
              cpu: "250m"
              memory: "512Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: pyroscope
  namespace: ${PYROSCOPE_NAMESPACE}
spec:
  selector:
    app: pyroscope
  ports:
    - port: 4040
      targetPort: 4040
PYROSCOPE

  oc wait --for=condition=available deployment/pyroscope \
    -n "${PYROSCOPE_NAMESPACE}" --timeout=120s
  echo "── Pyroscope ready at ${PYROSCOPE_URL} ──"
fi


# ─── 4. DEPLOY LCS (library mode + mock LLM sidecar) ────────────────────────

echo "── Deploying lightspeed-core ──"

# 4a. Create ConfigMaps from heredocs
cat <<'LCS_STACK_CONFIG' | envsubst | oc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: lcs-config
  namespace: ${LCS_NAMESPACE}
data:
  lightspeed-stack.yaml: |
    service:
      port: 8080
      workers: ${LCS_WORKERS}

    ogx:
      use_as_library_client: true
      library_client_config_path: /app/config/run.yaml
      timeout: 120

    auth:
      module: "noop"

    logging_config:
      app_log_level: info

  run.yaml: |
    version: v2
    apis:
      - inference
      - safety
      - vector_io
      - agents
      - tool_runtime
      - files
    providers:
      inference:
        - provider_id: mock-llm
          provider_type: remote::openai
          config:
            url: http://localhost:11434/v1
            api_key: fake-key
      safety:
        - provider_id: llama-guard
          provider_type: inline::llama-guard
          config: {}
      vector_io:
        - provider_id: faiss
          provider_type: inline::faiss
          config:
            kvstore:
              type: sqlite
              db_path: /tmp/faiss_store.db
      agents:
        - provider_id: meta-reference
          provider_type: inline::meta-reference
          config:
            persistence_store:
              type: sqlite
              db_path: /tmp/agents_store.db
    metadata_store:
      type: sqlite
      db_path: /tmp/registry.db
LCS_STACK_CONFIG

# 4b. Deploy LCS with mock LLM sidecar
PYROSCOPE_ENV=""
if [[ "${ENABLE_PYROSCOPE}" == "true" ]]; then
  PYROSCOPE_ENV="
            - name: PYROSCOPE_SERVER_ADDRESS
              value: \"${PYROSCOPE_URL}\""
fi

MEMRAY_CMD=""
if [[ "${ENABLE_MEMRAY}" == "true" ]]; then
  MEMRAY_CMD='["memray", "run", "--output", "/mnt/profiling/memray-output.bin", "-m", "uvicorn", "src.app.main:app", "--host", "0.0.0.0", "--port", "8080"]'
fi

cat <<DEPLOYMENT | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: lcs
  namespace: ${LCS_NAMESPACE}
  labels:
    app: lcs
spec:
  replicas: 1
  selector:
    matchLabels:
      app: lcs
  template:
    metadata:
      labels:
        app: lcs
        app.kubernetes.io/name: lightspeed-core-service
    spec:
      containers:
        - name: lcs
          image: ${LCS_APP_IMAGE}
          ports:
            - containerPort: 8080
          env:
            - name: OLS_CONFIG_FILE
              value: "/app-config/lightspeed-stack.yaml"
            - name: OTEL_SDK_DISABLED
              value: "true"${PYROSCOPE_ENV}
          volumeMounts:
            - name: config-volume
              mountPath: /app-config
            - name: profiling-volume
              mountPath: /mnt/profiling
          resources:
            requests:
              cpu: "1"
              memory: "2Gi"
            limits:
              cpu: "2"
              memory: "4Gi"
          readinessProbe:
            httpGet:
              path: /readiness
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
          livenessProbe:
            httpGet:
              path: /liveness
              port: 8080
            initialDelaySeconds: 30
            periodSeconds: 15
            timeoutSeconds: 5
        - name: mock-llm
          image: ${MOCK_LLM_IMAGE}
          ports:
            - containerPort: 11434
          resources:
            requests:
              cpu: "250m"
              memory: "256Mi"
      volumes:
        - name: config-volume
          configMap:
            name: lcs-config
        - name: profiling-volume
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: lcs-service
  namespace: ${LCS_NAMESPACE}
  labels:
    app: lcs
spec:
  selector:
    app: lcs
  ports:
    - port: 8080
      targetPort: 8080
DEPLOYMENT

echo "── Waiting for LCS readiness ──"
oc wait --for=condition=available deployment/lcs \
  -n "${LCS_NAMESPACE}" --timeout=300s

# Verify LCS is responding
LCS_POD=$(oc get pods -n "${LCS_NAMESPACE}" -l app=lcs -o name | head -1)
echo "LCS pod: ${LCS_POD}"
oc exec -n "${LCS_NAMESPACE}" "${LCS_POD}" -c lcs -- \
  curl -sf http://localhost:8080/readiness || {
    echo "ERROR: LCS readiness check failed"
    oc logs -n "${LCS_NAMESPACE}" "${LCS_POD}" -c lcs --tail=50
    exit 1
  }
echo "── LCS is ready ──"


# ─── 5. CREATE KUBECONFIG SECRET FOR LOAD GENERATOR JOB ─────────────────────

echo "── Creating kubeconfig secret ──"
oc create secret generic kubeconfig-secret \
  -n "${LCS_NAMESPACE}" \
  --from-file=kubeconfig="${KUBECONFIG}" \
  --dry-run=client -o yaml | oc apply -f -


# ─── 6. RUN LOAD TESTS ──────────────────────────────────────────────────────

echo "══════════════════════════════════════════════════════════"
echo "  Starting load test: ${NUM_USERS} users × ${TEST_DURATION}"
echo "══════════════════════════════════════════════════════════"

# Record start time for profiling collection window
TEST_START_EPOCH=$(date +%s)

# Set env vars for envsubst in the Job manifest
export LCS_NAMESPACE LCS_LOADGEN_IMAGE LCS_HOST LCS_TOKEN
export LCS_PROVIDER LCS_MODEL ES_SERVER ES_INDEX
export LOCUST_USERS="${NUM_USERS}"
export LOCUST_RUN_TIME="${TEST_DURATION}"
export LOCUST_PROCESSES REQUEST_TIMEOUT METRIC_STEP

# The Job manifest is at /opt/lcs-load-generator/config/lcs-load-generator.yaml
# (baked into the step pod image from your Containerfile)
JOB_MANIFEST="/opt/lcs-load-generator/config/lcs-load-generator.yaml"

# Delete any previous Job (idempotent)
oc delete job lcs-load-generator -n "${LCS_NAMESPACE}" --ignore-not-found=true

# Apply the Job
echo "── Applying load generator Job ──"
envsubst < "${JOB_MANIFEST}" | oc apply -f -

# Wait for Job to complete (24h max — matches step timeout)
echo "── Waiting for Job completion ──"
oc wait --for=condition=complete job/lcs-load-generator \
  -n "${LCS_NAMESPACE}" --timeout=86400s || {
    echo "ERROR: Load generator Job failed or timed out"
    echo "── Job status ──"
    oc get job lcs-load-generator -n "${LCS_NAMESPACE}" -o yaml
    echo "── Job pod logs ──"
    JOB_POD=$(oc get pods -n "${LCS_NAMESPACE}" -l job-name=lcs-load-generator -o name | head -1)
    if [[ -n "${JOB_POD}" ]]; then
      oc logs -n "${LCS_NAMESPACE}" "${JOB_POD}" --tail=200
    fi
    exit 1
  }

TEST_END_EPOCH=$(date +%s)
TEST_DURATION_SECONDS=$((TEST_END_EPOCH - TEST_START_EPOCH))

echo "── Load test completed in ${TEST_DURATION_SECONDS}s ──"

# Collect Job logs to artifacts
JOB_POD=$(oc get pods -n "${LCS_NAMESPACE}" -l job-name=lcs-load-generator -o name | head -1)
if [[ -n "${JOB_POD}" ]]; then
  mkdir -p "${ARTIFACT_DIR}/logs"
  oc logs -n "${LCS_NAMESPACE}" "${JOB_POD}" > "${ARTIFACT_DIR}/logs/lcs-load-generator.log" 2>&1 || true
fi


# ─── 7. COLLECT PROFILING DATA ──────────────────────────────────────────────

echo "── Collecting profiling data ──"
mkdir -p "${ARTIFACT_DIR}/profiling-data"

# 7a. Pyroscope CPU profiles
if [[ "${ENABLE_PYROSCOPE}" == "true" ]]; then
  PROF_DIR="${ARTIFACT_DIR}/profiling-data/pyroscope"
  mkdir -p "${PROF_DIR}"

  echo "  Collecting Pyroscope profiles (${TEST_START_EPOCH} → ${TEST_END_EPOCH})"

  # pprof format (importable into Go pprof tools)
  curl -sS "${PYROSCOPE_URL}/render?query=process_cpu&from=${TEST_START_EPOCH}&until=${TEST_END_EPOCH}&format=pprof" \
    -o "${PROF_DIR}/cpu-profile.pprof" || echo "WARN: Pyroscope pprof export failed"

  # HTML flamegraph (viewable in browser from artifacts page)
  curl -sS "${PYROSCOPE_URL}/render?query=process_cpu&from=${TEST_START_EPOCH}&until=${TEST_END_EPOCH}&format=html" \
    -o "${PROF_DIR}/cpu-flamegraph.html" || echo "WARN: Pyroscope HTML export failed"

  # Collapsed stacks (for flamegraph.pl or speedscope)
  curl -sS "${PYROSCOPE_URL}/render?query=process_cpu&from=${TEST_START_EPOCH}&until=${TEST_END_EPOCH}&format=collapsed" \
    -o "${PROF_DIR}/cpu-collapsed.txt" || echo "WARN: Pyroscope collapsed export failed"

  # JSON format (for programmatic analysis)
  curl -sS "${PYROSCOPE_URL}/render?query=process_cpu&from=${TEST_START_EPOCH}&until=${TEST_END_EPOCH}&format=json" \
    -o "${PROF_DIR}/cpu-profile.json" || echo "WARN: Pyroscope JSON export failed"

  echo "  Pyroscope profiles saved to ${PROF_DIR}"
fi

# 7b. Memray memory profiles (if enabled)
if [[ "${ENABLE_MEMRAY}" == "true" ]]; then
  MEM_DIR="${ARTIFACT_DIR}/profiling-data/memray"
  mkdir -p "${MEM_DIR}"

  LCS_POD=$(oc get pods -n "${LCS_NAMESPACE}" -l app=lcs -o name | head -1)
  if [[ -n "${LCS_POD}" ]]; then
    echo "  Collecting Memray profiles from ${LCS_POD}"

    # Generate flamegraph HTML
    oc exec -n "${LCS_NAMESPACE}" "${LCS_POD}" -c lcs -- \
      memray flamegraph -o /tmp/memray-flamegraph.html /mnt/profiling/memray-output.bin 2>/dev/null || true
    oc cp "${LCS_NAMESPACE}/${LCS_POD#pod/}:/tmp/memray-flamegraph.html" \
      "${MEM_DIR}/memray-flamegraph.html" 2>/dev/null || true

    # Generate stats
    oc exec -n "${LCS_NAMESPACE}" "${LCS_POD}" -c lcs -- \
      memray stats /mnt/profiling/memray-output.bin > "${MEM_DIR}/memray-stats.txt" 2>/dev/null || true

    # Generate summary
    oc exec -n "${LCS_NAMESPACE}" "${LCS_POD}" -c lcs -- \
      memray summary /mnt/profiling/memray-output.bin > "${MEM_DIR}/memray-summary.txt" 2>/dev/null || true

    # Copy raw binary (for offline analysis)
    oc cp "${LCS_NAMESPACE}/${LCS_POD#pod/}:/mnt/profiling/memray-output.bin" \
      "${MEM_DIR}/memray-output.bin" 2>/dev/null || true

    echo "  Memray profiles saved to ${MEM_DIR}"
  else
    echo "WARN: Could not find LCS pod for Memray collection"
  fi
fi

# 7c. Collect LCS pod logs
echo "  Collecting LCS pod logs"
LCS_POD=$(oc get pods -n "${LCS_NAMESPACE}" -l app=lcs -o name | head -1)
if [[ -n "${LCS_POD}" ]]; then
  oc logs -n "${LCS_NAMESPACE}" "${LCS_POD}" -c lcs > "${ARTIFACT_DIR}/logs/lcs-app.log" 2>&1 || true
  oc logs -n "${LCS_NAMESPACE}" "${LCS_POD}" -c mock-llm > "${ARTIFACT_DIR}/logs/mock-llm.log" 2>&1 || true
fi


# ─── 8. SUMMARY ─────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  LCS Performance Test — Complete                        ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Duration:     ${TEST_DURATION_SECONDS}s"
echo "║  Users:        ${NUM_USERS}"
echo "║  ES Index:     ${ES_INDEX}"
echo "║  Artifacts:    ${ARTIFACT_DIR}"
echo "║  Pyroscope:    ${ENABLE_PYROSCOPE}"
echo "║  Memray:       ${ENABLE_MEMRAY}"
echo "╚══════════════════════════════════════════════════════════╝"

ls -la "${ARTIFACT_DIR}/profiling-data/" 2>/dev/null || true
ls -la "${ARTIFACT_DIR}/logs/" 2>/dev/null || true

echo "── Done ──"
