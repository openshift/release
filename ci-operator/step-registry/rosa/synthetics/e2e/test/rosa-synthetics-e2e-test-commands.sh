#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

FAILURES=0
fail() { echo "FAIL  $*" >&2; FAILURES=$((FAILURES + 1)); }
pass() { echo "PASS  $*" >&2; }
log() { echo -e "\033[1m$(date "+%H:%M:%S") $*\033[0m" >&2; }

# --- Install CLI tools ---
BIN="${HOME}/bin"
mkdir -p "${BIN}"
export PATH="${BIN}:${PATH}"
curl -sfSL -o "${BIN}/ocm" "https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64" && chmod +x "${BIN}/ocm"
BP_VERSION=$(curl -sfSL "https://api.github.com/repos/openshift/backplane-cli/releases/latest" | python3 -c "import json,sys;print(json.load(sys.stdin)['tag_name'].lstrip('v'))")
curl -sfSL "https://github.com/openshift/backplane-cli/releases/latest/download/ocm-backplane_${BP_VERSION}_Linux_x86_64.tar.gz" | tar xzf - --no-same-owner -C "${BIN}" ocm-backplane
curl -sfSL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz" | tar xzf - --no-same-owner -C "${BIN}" oc kubectl

NS=$(cat "${SHARED_DIR}/e2e-namespace")
MOCK_API_URL=$(cat "${SHARED_DIR}/mock-api-url")
log "Namespace: ${NS}"
log "Component: ${COMPONENT}"
log "Mock API:  ${MOCK_API_URL}"

# --- OCM login + backplane ---
SSO_CLIENT_ID=$(cat /usr/local/rosa-e2e-credentials/sso-client-id)
SSO_CLIENT_SECRET=$(cat /usr/local/rosa-e2e-credentials/sso-client-secret)
ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
mkdir -p "${HOME}/.config/backplane"
cat > "${HOME}/.config/backplane/config.json" <<EOF
{"proxy-url": "http://squid.corp.redhat.com:3128"}
EOF
ocm backplane login "${RHOBS_CLUSTER_ID}"

ELEVATE_REASON="https://redhat.atlassian.net/browse/ROSAENG-62319"
ocm backplane elevate "${ELEVATE_REASON}"
oce() { ocm backplane elevate "" -- "$@"; }

if [[ "${COMPONENT}" == "agent" ]]; then
  log "--- Deploying synthetics-agent ---"

  # Create RBAC for the agent
  cat <<YAML | oce apply -n "${NS}" -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: synthetics-agent
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: synthetics-agent
rules:
- apiGroups: ["monitoring.rhobs"]
  resources: ["probes", "prometheuses", "servicemonitors"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["monitoring.coreos.com"]
  resources: ["probes", "prometheuses", "servicemonitors"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["services", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch", "create", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: synthetics-agent
subjects:
- kind: ServiceAccount
  name: synthetics-agent
roleRef:
  kind: Role
  name: synthetics-agent
  apiGroup: rbac.authorization.k8s.io
YAML

  log "Agent image: ${AGENT_IMAGE}"

  # Deploy the agent
  cat <<YAML | oce apply -n "${NS}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: synthetics-agent
  labels:
    app: synthetics-agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: synthetics-agent
  template:
    metadata:
      labels:
        app: synthetics-agent
    spec:
      serviceAccountName: synthetics-agent
      imagePullSecrets:
      - name: ci-pull-secret
      containers:
      - name: agent
        image: ${AGENT_IMAGE}
        args:
        - start
        - --log-level=debug
        - --interval=5s
        - --namespace=${NS}
        - --api-urls=${MOCK_API_URL}
        - --prometheus-api-group=monitoring.rhobs
        ports:
        - containerPort: 8080
        env:
        - name: NAMESPACE
          value: "${NS}"
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: synthetics-agent
spec:
  selector:
    app: synthetics-agent
  ports:
  - port: 8080
    targetPort: 8080
YAML

  log "Waiting for agent to be ready"
  for i in $(seq 1 60); do
    AVAIL=$(oce get deployment/synthetics-agent -n "${NS}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
    if [[ "${AVAIL}" == "1" ]]; then
      log "Agent deployment ready"
      break
    fi
    if [[ $i -eq 60 ]]; then
      fail "Agent deployment not ready after 300s"
      oce describe deployment/synthetics-agent -n "${NS}" || true
      exit 1
    fi
    sleep 5
  done

  # Give agent time to poll mock API and reconcile
  log "Waiting 30s for agent to reconcile"
  sleep 30

  # --- Verify agent behavior ---
  log "--- Verification ---"
  AGENT_POD=$(oce get pod -n "${NS}" -l app=synthetics-agent -o jsonpath='{.items[0].metadata.name}')

  # Check readiness
  READY_STATUS=$(oce exec -n "${NS}" "${AGENT_POD}" -- curl -sf --max-time 10 http://localhost:8080/readyz 2>/dev/null || true)
  if [[ -n "${READY_STATUS}" ]]; then
    pass "/readyz: ${READY_STATUS}"
  else
    fail "/readyz: not ready (got: ${READY_STATUS})"
  fi

  # Check metrics endpoint
  METRICS=$(oce exec -n "${NS}" "${AGENT_POD}" -- curl -sf --max-time 10 http://localhost:8080/metrics 2>/dev/null || true)
  if echo "${METRICS}" | grep -q "rhobs_synthetics_agent_info"; then
    pass "/metrics: agent metrics present"
  else
    fail "/metrics: missing rhobs_synthetics_agent_info"
  fi

  if echo "${METRICS}" | grep -q "rhobs_synthetics_agent_reconciliation_total"; then
    pass "/metrics: reconciliation counter present"
  else
    fail "/metrics: missing reconciliation counter"
  fi

  # Check Probe CRDs created
  PROBE_COUNT=$(oce get probes.monitoring.rhobs -n "${NS}" --no-headers 2>/dev/null | wc -l || true)
  if [[ -n "${PROBE_COUNT}" && "${PROBE_COUNT}" -gt 0 ]]; then
    pass "Probe CRDs: ${PROBE_COUNT} created"
  else
    # Try monitoring.coreos.com as fallback
    PROBE_COUNT=$(oce get probes.monitoring.coreos.com -n "${NS}" --no-headers 2>/dev/null | wc -l || true)
    if [[ -n "${PROBE_COUNT}" && "${PROBE_COUNT}" -gt 0 ]]; then
      pass "Probe CRDs (coreos): ${PROBE_COUNT} created"
    else
      log "WARN  Probe CRDs: none created (0 probes on integration is expected)"
    fi
  fi

  # Check blackbox exporter deployed
  BB_READY=$(oce get deployment -n "${NS}" -l "prober.synthetics-agent.rhobs" --no-headers 2>/dev/null | wc -l || true)
  if [[ -n "${BB_READY}" && "${BB_READY}" -gt 0 ]]; then
    pass "Blackbox exporter: deployed"
  else
    fail "Blackbox exporter: not found"
  fi

  # Dump agent logs for debugging
  log "--- Agent logs ---"
  oce logs deployment/synthetics-agent -n "${NS}" --tail=50 || true

elif [[ "${COMPONENT}" == "api" ]]; then
  log "--- Deploying synthetics-api ---"

  cat <<YAML | oce apply -n "${NS}" -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: synthetics-api
  labels:
    app: synthetics-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: synthetics-api
  template:
    metadata:
      labels:
        app: synthetics-api
    spec:
      automountServiceAccountToken: false
      containers:
      - name: api
        image: ${API_IMAGE}
        securityContext:
          allowPrivilegeEscalation: false
          runAsNonRoot: true
          capabilities:
            drop: ["ALL"]
        args:
        - --database-engine=local
        - --data-dir=/tmp/synthetics-data
        - --port=8080
        - --log-level=debug
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /readyz
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: synthetics-api
spec:
  selector:
    app: synthetics-api
  ports:
  - port: 8080
    targetPort: 8080
YAML

  log "Waiting for API to be ready"
  for i in $(seq 1 60); do
    AVAIL=$(oce get deployment/synthetics-api -n "${NS}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
    if [[ "${AVAIL}" == "1" ]]; then
      log "API deployment ready"
      break
    fi
    if [[ $i -eq 60 ]]; then
      fail "API deployment not ready after 300s"
      exit 1
    fi
    sleep 5
  done

  log "--- Verification ---"
  API_POD=$(oce get pod -n "${NS}" -l app=synthetics-api -o jsonpath='{.items[0].metadata.name}')

  READY_STATUS=$(oce exec -n "${NS}" "${API_POD}" -- curl -sf --max-time 10 http://localhost:8080/readyz 2>/dev/null || true)
  if [[ -n "${READY_STATUS}" ]]; then
    pass "/readyz: ${READY_STATUS}"
  else
    fail "/readyz: not ready"
  fi

  PROBES=$(oce exec -n "${NS}" "${API_POD}" -- curl -sf --max-time 10 http://localhost:8080/probes 2>/dev/null || true)
  if [[ -n "${PROBES}" ]]; then
    pass "/probes: responding"
  else
    fail "/probes: no response"
  fi

  METRICS=$(oce exec -n "${NS}" "${API_POD}" -- curl -sf --max-time 10 http://localhost:8080/metrics 2>/dev/null || true)
  if echo "${METRICS}" | grep -q "promhttp_metric_handler"; then
    pass "/metrics: responding"
  else
    fail "/metrics: missing expected metrics"
  fi

else
  log "ERROR: unknown COMPONENT=${COMPONENT}, expected 'agent' or 'api'"
  exit 1
fi

echo ""
if [[ ${FAILURES} -gt 0 ]]; then
  log "FAILED: ${FAILURES} check(s) failed"
  exit 1
fi
log "PASSED: all checks passed"
