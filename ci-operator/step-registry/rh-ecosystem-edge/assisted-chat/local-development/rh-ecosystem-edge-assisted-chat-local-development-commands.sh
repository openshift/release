#!/bin/bash

set -euxo pipefail

NAMESPACE="assisted-chat-local-dev"
POD_NAME="assisted-chat-local-dev"
CONTAINER_NAME="runner"

echo "[SETUP] ensure namespace"
oc get ns "$NAMESPACE" >/dev/null 2>&1 || oc create ns "$NAMESPACE"

# Prepare secrets in target namespace from credentials mounted into this job container
create_or_update_secret() {
  local name="$1"; shift
  local args=("$@")
  if oc -n "$NAMESPACE" get secret "$name" >/dev/null 2>&1; then
    echo "[SECRETS] updating secret $name"
  else
    echo "[SECRETS] creating secret $name"
  fi
  # use apply via dry-run yaml to be idempotent
  oc -n "$NAMESPACE" create secret generic "$name" "${args[@]}" --dry-run=client -o yaml | oc -n "$NAMESPACE" apply -f -
}

# Gemini API key
if [ -f /var/run/secrets/gemini/api_key ]; then
  create_or_update_secret assisted-chat-gemini-api-key \
    --from-file=api_key=/var/run/secrets/gemini/api_key
else
  echo "[SECRETS][WARN] /var/run/secrets/gemini/api_key not found; skipping gemini secret"
fi
# Vertex service account
if [ -f /var/run/secrets/vertex/service_account ]; then
  create_or_update_secret assisted-chat-vertex-service-account \
    --from-file=service_account=/var/run/secrets/vertex/service_account
else
  echo "[SECRETS][WARN] /var/run/secrets/vertex/service_account not found; skipping vertex secret"
fi
# SSO CI client credentials (include all files from dir)
if [ -d /var/run/secrets/sso-ci ]; then
  create_or_update_secret assisted-chat-sso-ci \
    --from-file=/var/run/secrets/sso-ci
else
  echo "[SECRETS][WARN] /var/run/secrets/sso-ci not found; skipping sso secret"
fi

echo "[SETUP] create/update ServiceAccount and grant SCCs"
oc -n "$NAMESPACE" create sa runner || true
# Grant privileged/anyuid for nested podman use
oc -n "$NAMESPACE" adm policy add-scc-to-user privileged -z runner || true
oc -n "$NAMESPACE" adm policy add-scc-to-user anyuid -z runner || true

echo "[SETUP] create ConfigMap with runner script from repo"
oc -n "$NAMESPACE" delete cm local-dev-runner --ignore-not-found
oc -n "$NAMESPACE" create configmap local-dev-runner \
  --from-file=local-dev-runner.sh=scripts/ci/local-dev-runner.sh

echo "[POD] apply privileged pod manifest"
cat > /tmp/local-dev-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: assisted-chat-local-dev
spec:
  serviceAccountName: runner
  restartPolicy: Never
  containers:
  - name: runner
    image: registry.ci.openshift.org/ci/nested-podman:latest
    imagePullPolicy: IfNotPresent
    command: ["/bin/bash","-lc","sleep 7200"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: runner-cm
      mountPath: /opt/runner
      readOnly: true
    - name: gemini
      mountPath: /var/run/secrets/gemini
      readOnly: true
    - name: vertex
      mountPath: /var/run/secrets/vertex
      readOnly: true
    - name: sso
      mountPath: /var/run/secrets/sso-ci
      readOnly: true
  volumes:
  - name: runner-cm
    configMap:
      name: local-dev-runner
      defaultMode: 0755
  - name: gemini
    secret:
      secretName: assisted-chat-gemini-api-key
  - name: vertex
    secret:
      secretName: assisted-chat-vertex-service-account
  - name: sso
    secret:
    secretName: assisted-chat-sso-ci
EOF

oc -n "$NAMESPACE" delete pod "$POD_NAME" --ignore-not-found
oc -n "$NAMESPACE" apply -f /tmp/local-dev-pod.yaml

echo "[POD] waiting for Ready (up to 10m)"
if ! oc -n "$NAMESPACE" wait --for=condition=Ready pod/"$POD_NAME" --timeout=10m; then
  echo "[DIAG] describe pod"
  oc -n "$NAMESPACE" describe pod "$POD_NAME" || true
  echo "[DIAG] recent events"
  oc -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -n 50 || true
  echo "[ERROR] pod did not become Ready"
  exit 1
fi

echo "[PREP] installing required tools in container (git, make, jq, tar, gzip, python3, pip)"
oc -n "$NAMESPACE" exec "$POD_NAME" -c "$CONTAINER_NAME" -- bash -lc '
  set -eux; 
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install git make jq tar gzip python3 python3-pip || true; dnf clean all || true;
  elif command -v microdnf >/dev/null 2>&1; then
    microdnf -y install git make jq tar gzip python3 python3-pip || true; microdnf clean all || true;
  elif command -v yum >/dev/null 2>&1; then
    yum -y install git make jq tar gzip python3 python3-pip || true; yum clean all || true;
  fi'

echo "[COPY] copying repository into pod:/workspace"
oc -n "$NAMESPACE" cp . "$POD_NAME":/workspace -c "$CONTAINER_NAME"

echo "[EXEC] launching runner"
oc -n "$NAMESPACE" exec "$POD_NAME" -c "$CONTAINER_NAME" -- bash -lc "cd /workspace && /opt/runner/local-dev-runner.sh" 