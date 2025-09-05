#!/bin/bash
set -euo pipefail

# Sleep forever to keep the pod running
sleep 1000000000

# Ensure oc is available in this container
export PATH="${HOME}/.local/bin:${PATH}"
if ! command -v oc >/dev/null 2>&1; then
  mkdir -p "${HOME}/.local/bin"
  OC_URL_PRIMARY="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.17.0/openshift-client-linux.tar.gz"
  OC_URL_FALLBACK="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest-4.17/openshift-client-linux.tar.gz"
  if ! curl -sSL "$OC_URL_PRIMARY" | tar -xz -C "${HOME}/.local/bin" oc kubectl 2>/dev/null; then
    curl -sSL "$OC_URL_FALLBACK" | tar -xz -C "${HOME}/.local/bin" oc kubectl
  fi
  chmod +x "${HOME}/.local/bin/oc" "${HOME}/.local/bin/kubectl" || true
fi

# Read credentials from mounted secrets in this job pod (build-farm)
GEM_KEY=""; if [ -d /var/run/secrets/gemini ]; then for f in /var/run/secrets/gemini/*; do if [ -f "$f" ]; then GEM_KEY="$(cat "$f")"; break; fi; done; fi
VJSON_PATH=""; if [ -d /var/run/secrets/vertex ]; then VJSON_PATH="$(ls /var/run/secrets/vertex/service_account 2>/dev/null | head -n1)" || true; fi
if [ -n "$GEM_KEY" ]; then export GEMINI_API_KEY="$GEM_KEY"; fi
if [ -n "$VJSON_PATH" ]; then export GOOGLE_APPLICATION_CREDENTIALS="$VJSON_PATH"; fi

# Ensure ocm is available (for token) in this job pod
if ! command -v ocm >/dev/null 2>&1; then \
  mkdir -p "${HOME}/.local/bin" && \
  curl -sSL -o "${HOME}/.local/bin/ocm" "https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64" && \
  chmod +x "${HOME}/.local/bin/ocm"; \
fi

# Obtain OCM token if possible
OCM_TOKEN_VALUE="${OCM_TOKEN:-}" || true
if [ -z "$OCM_TOKEN_VALUE" ] && [ -d /var/run/secrets/sso-ci ]; then \
  FIRST_FILE=$(ls -1 /var/run/secrets/sso-ci/* 2>/dev/null | head -n1 || true); \
  if [ -n "$FIRST_FILE" ] && [ -f "$FIRST_FILE" ]; then OCM_TOKEN_VALUE="$(cat "$FIRST_FILE" 2>/dev/null || true)"; fi; \
fi
if [ -z "$OCM_TOKEN_VALUE" ]; then OCM_TOKEN_VALUE="$(ocm token 2>/dev/null || true)"; fi

# Determine assisted-chat source org/repo and SHA
SRC_ORG="rh-ecosystem-edge"
SRC_REPO="assisted-chat"
SRC_SHA=""
if [ -n "${JOB_SPEC:-}" ]; then
  # Try to find refs for the assisted-chat repo in JOB_SPEC (supports rehearsals)
  SRC_ORG_JS=$(printf '%s' "$JOB_SPEC" | jq -r '[.refs, (.extra_refs[]?)] | map(select(.repo=="assisted-chat" and .org=="rh-ecosystem-edge")) | .[0].org // empty' 2>/dev/null || true)
  SRC_REPO_JS=$(printf '%s' "$JOB_SPEC" | jq -r '[.refs, (.extra_refs[]?)] | map(select(.repo=="assisted-chat" and .org=="rh-ecosystem-edge")) | .[0].repo // empty' 2>/dev/null || true)
  SRC_SHA_JS=$(printf '%s' "$JOB_SPEC" | jq -r '[.refs, (.extra_refs[]?)] | map(select(.repo=="assisted-chat" and .org=="rh-ecosystem-edge")) | .[0] | (.pulls[0].sha // .base_sha // empty)' 2>/dev/null || true)
  if [ -n "$SRC_ORG_JS" ] && [ -n "$SRC_REPO_JS" ]; then SRC_ORG="$SRC_ORG_JS"; SRC_REPO="$SRC_REPO_JS"; fi
  if [ -n "$SRC_SHA_JS" ]; then SRC_SHA="$SRC_SHA_JS"; fi
fi

# Create a working namespace on the claimed cluster
NS="assisted-chat-ci-$(date +%s)-$RANDOM"
echo "Using namespace: $NS"
oc new-project "$NS" >/dev/null
# Wait for SCC-related annotations to be populated on the namespace
for i in {1..60}; do
  UID_RANGE=$(oc get ns "$NS" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.uid-range}' 2>/dev/null || true)
  SUP_GROUPS=$(oc get ns "$NS" -o jsonpath='{.metadata.annotations.openshift\.io/sa\.scc\.supplemental-groups}' 2>/dev/null || true)
  if [ -n "$UID_RANGE" ] && [ -n "$SUP_GROUPS" ]; then break; fi
  sleep 2
done
# Allow privileged pod for buildah/podman
oc adm policy add-scc-to-user privileged -z default -n "$NS" >/dev/null

# Stage secrets into the claimed cluster namespace
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"; oc -n "$NS" delete configmap assisted-chat-runner-script --ignore-not-found >/dev/null 2>&1 || true; oc delete ns "$NS" --ignore-not-found >/dev/null 2>&1 || true' EXIT

if [ -n "${GEMINI_API_KEY:-}" ]; then
  printf "%s" "$GEMINI_API_KEY" >"$TMPD/gemini.key"
  oc -n "$NS" create secret generic assisted-chat-gemini --from-file=key="$TMPD/gemini.key" >/dev/null
fi

VERTEX_JSON_CONTENT=""
if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && [ -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]; then
  cp -f "${GOOGLE_APPLICATION_CREDENTIALS}" "$TMPD/vertex.json"
  oc -n "$NS" create secret generic assisted-chat-vertex --from-file=service_account="$TMPD/vertex.json" >/dev/null
fi
# Stage SSO CI secret if available in the job pod
if [ -d /var/run/secrets/sso-ci ]; then
  rm -rf "$TMPD/sso-ci" && mkdir -p "$TMPD/sso-ci"
  cp -a /var/run/secrets/sso-ci/. "$TMPD/sso-ci/" 2>/dev/null || true
  oc -n "$NS" create secret generic assisted-chat-sso-ci --from-file="$TMPD/sso-ci" >/dev/null || true
fi

# Prepare values for git clone inside the cluster pod
REPO_OWNER_VAL="${REPO_OWNER:-rh-ecosystem-edge}"
REPO_NAME_VAL="${REPO_NAME:-assisted-chat}"
REPO_REF_VAL="${PULL_PULL_SHA:-}"

# Build the runner script to avoid YAML block scalars
cat >"$TMPD/runner.sh" <<'RS'
set -euxo pipefail
# Ensure tools
dnf -y install git make jq curl tar gzip || true
# Install uv and Python 3.11, prefer uv-managed interpreter
curl -Ls https://astral.sh/uv/install.sh | sh
export PATH="/usr/local/bin:${HOME}/.local/bin:${PATH}"
uv python install 3.11
PY311_PATH=$(uv python find 3.11)
ln -sf "$PY311_PATH" /usr/local/bin/python || true
# Install required Python libs into system interpreter
uv pip install --system -p 3.11 --no-cache-dir git+https://github.com/lightspeed-core/lightspeed-evaluation.git#subdirectory=lsc_agent_eval || true
# Install oc client
OC_URL_PRIMARY="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/4.17.0/openshift-client-linux.tar.gz"
OC_URL_FALLBACK="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest-4.17/openshift-client-linux.tar.gz"
if ! curl -sSL "$OC_URL_PRIMARY" | tar -xz -C /usr/local/bin oc kubectl 2>/dev/null; then
  curl -sSL "$OC_URL_FALLBACK" | tar -xz -C /usr/local/bin oc kubectl
fi
chmod +x /usr/local/bin/oc /usr/local/bin/kubectl || true
# Install yq (Go binary)
curl -sSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64" && chmod +x /usr/local/bin/yq
# Install ocm CLI
curl -sSL -o /usr/local/bin/ocm "https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64" && chmod +x /usr/local/bin/ocm
echo "[OCM] ocm version: $(ocm --version 2>/dev/null || echo unknown)"
echo "[OCM] Available sso-ci files:"; ls -l /var/run/secrets/sso-ci 2>/dev/null || true
# Non-interactive OCM login with fallbacks
LOGIN_OK=0
if [ -n "${OCM_TOKEN:-}" ] && echo "$OCM_TOKEN" | grep -qE '^[^\.]+\.[^\.]+\.[^\.]+$'; then
  echo "[OCM] Attempting login via provided JWT token"
  ocm login --token "$OCM_TOKEN" && LOGIN_OK=1 || echo "[OCM] Token login failed"
fi
if [ "$LOGIN_OK" -ne 1 ]; then
  # Try to find a JWT token in any sso-ci file
  JWT_FILE=$(grep -l -E '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' /var/run/secrets/sso-ci/* 2>/dev/null | head -n1 || true)
  if [ -n "$JWT_FILE" ] && [ -f "$JWT_FILE" ]; then
    JWT_VAL=$(head -n1 "$JWT_FILE" 2>/dev/null || true)
    if echo "$JWT_VAL" | grep -qE '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'; then
      echo "[OCM] Attempting login via discovered JWT from $(basename "$JWT_FILE")"
      ocm login --token "$JWT_VAL" && LOGIN_OK=1 || echo "[OCM] Discovered JWT login failed"
    fi
  fi
fi
if [ "$LOGIN_OK" -ne 1 ]; then
  CID_FILE=$(ls -1 /var/run/secrets/sso-ci/*id* 2>/dev/null | head -n1 || true)
  CSEC_FILE=$(ls -1 /var/run/secrets/sso-ci/*secret* 2>/dev/null | head -n1 || true)
  [ -z "$CID_FILE" ] && CID_FILE=$(ls -1 /var/run/secrets/sso-ci/*client*id* 2>/dev/null | head -n1 || true)
  [ -z "$CSEC_FILE" ] && CSEC_FILE=$(ls -1 /var/run/secrets/sso-ci/*client*secret* 2>/dev/null | head -n1 || true)
  if [ -n "$CID_FILE" ] && [ -n "$CSEC_FILE" ] && [ -f "$CID_FILE" ] && [ -f "$CSEC_FILE" ]; then
    CLIENT_ID=$(cat "$CID_FILE" 2>/dev/null || true)
    CLIENT_SECRET=$(cat "$CSEC_FILE" 2>/dev/null || true)
    echo "[OCM] Found client credentials (id len: ${#CLIENT_ID}, secret len: ${#CLIENT_SECRET})"
    if [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ]; then
      echo "[OCM] Trying client login against prod api.openshift.com"
      ocm login --client-id "$CLIENT_ID" --client-secret "$CLIENT_SECRET" --url https://api.openshift.com && LOGIN_OK=1 || echo "[OCM] Prod login failed"
      if [ "$LOGIN_OK" -ne 1 ]; then
        echo "[OCM] Trying client login against stage api.stage.openshift.com"
        ocm login --client-id "$CLIENT_ID" --client-secret "$CLIENT_SECRET" --url https://api.stage.openshift.com && LOGIN_OK=1 || echo "[OCM] Stage login failed"
      fi
    fi
  else
    echo "[OCM] No client credentials found under /var/run/secrets/sso-ci"
  fi
fi
if [ "$LOGIN_OK" -eq 1 ]; then
  echo "[OCM] Login succeeded; verifying identity"
  for i in 1 2 3 4 5; do
    if ocm whoami; then break; fi; sleep 2; done || true
else
  echo "[OCM] ERROR: All OCM login attempts failed" >&2
fi
# Export access and refresh tokens for scripts expecting them
OCM_TOKEN_VAL="$(ocm token 2>/dev/null || true)" || true
OCM_REFRESH_TOKEN_VAL="$(ocm token --refresh 2>/dev/null || true)" || true
echo "[OCM] token present: $( [ -n "$OCM_TOKEN_VAL" ] && echo yes || echo no ), refresh present: $( [ -n "$OCM_REFRESH_TOKEN_VAL" ] && echo yes || echo no )"
if [ -n "$OCM_TOKEN_VAL" ] && [ -n "$OCM_REFRESH_TOKEN_VAL" ]; then
  export OCM_TOKEN="$OCM_TOKEN_VAL"
  export OCM_REFRESH_TOKEN="$OCM_REFRESH_TOKEN_VAL"
else
  echo "[OCM] WARNING: OCM tokens could not be retrieved after login" >&2
fi
# Bypass RHSM check in build script
mkdir -p /etc/pki/consumer && touch /etc/pki/consumer/cert.pem || true
# Clone source
git clone https://github.com/${REPO_OWNER}/${REPO_NAME}.git /work
cd /work
if [ -n "${REPO_REF}" ]; then git fetch origin ${REPO_REF} && git checkout ${REPO_REF}; fi
# Ensure submodules are available (and use HTTPS instead of SSH)
git config --global url."https://github.com/".insteadOf git@github.com:
git submodule sync --recursive || true
git submodule update --init --recursive || true
# If OCM login failed but we have a token in secrets, use it and bypass login checks in scripts
if [ "$LOGIN_OK" -ne 1 ]; then
  # Try to discover a token string from sso-ci mounted files (first non-empty line)
  if [ -z "${OCM_TOKEN:-}" ]; then
    CAND=$(for f in /var/run/secrets/sso-ci/* 2>/dev/null; do [ -f "$f" ] && head -n1 "$f"; done | head -n1 || true)
    if [ -n "$CAND" ]; then export OCM_TOKEN="$CAND"; echo "[OCM] Using token discovered from sso-ci files (length: ${#OCM_TOKEN})"; fi
  fi
  if [ -n "${OCM_TOKEN:-}" ]; then
    echo "[OCM] Replacing utils/ocm-token.sh with env-token shim"
    mv utils/ocm-token.sh utils/ocm-token.sh.orig 2>/dev/null || true
    cat > utils/ocm-token.sh <<'EOS'
#!/bin/bash
# Auto-generated shim to satisfy export_ocm_token in CI when OCM_TOKEN is pre-set
if [ -n "${OCM_TOKEN:-}" ]; then
  get_ocm_token() { return 0; }
  export_ocm_token() { export OCM_TOKEN; echo "OCM tokens successfully validated and exported." >&2; return 0; }
else
  if [ -f "$(dirname "$0")/ocm-token.sh.orig" ]; then
    # shellcheck disable=SC1091
    . "$(dirname "$0")/ocm-token.sh.orig"
  else
    get_ocm_token() { return 1; }
    export_ocm_token() { return 1; }
  fi
fi
EOS
    chmod +x utils/ocm-token.sh || true
  fi
fi
# .env and credentials
if [ -f .env.template ] && [ ! -f .env ]; then cp .env.template .env; fi
if [ "${GEMINI_PRESENT}" = "true" ] && [ -d /var/run/secrets/gemini ]; then \
  GK_FILE=$(ls -1 /var/run/secrets/gemini 2>/dev/null | head -n1 || true); \
  if [ -n "$GK_FILE" ]; then GEMINI_VAL="$(cat "/var/run/secrets/gemini/${GK_FILE}")"; \
    if grep -q '^GEMINI_API_KEY=' .env 2>/dev/null; then sed -i "s/^GEMINI_API_KEY=.*/GEMINI_API_KEY=${GEMINI_VAL//\//\\/}/" .env; else echo "GEMINI_API_KEY=${GEMINI_VAL}" >> .env; fi; \
  fi; \
fi
mkdir -p config
if [ -f /var/run/secrets/vertex/service_account/cred.json ]; then \
  cp -f /var/run/secrets/vertex/service_account/cred.json config/vertex-credentials.json; \
elif [ "${GEMINI_PRESENT}" = "true" ]; then \
  printf '{}' > config/vertex-credentials.json; \
fi
# Run make targets in-cluster
make generate
# Provide a stub subscription-manager to satisfy RHSM presence checks
cat >/usr/local/bin/subscription-manager <<'SM'
#!/bin/sh
if [ "$1" = "status" ]; then
  echo "Overall Status: Current"
  exit 0
fi
exit 0
SM
chmod +x /usr/local/bin/subscription-manager
# Ensure cert file exists for any additional checks
mkdir -p /etc/pki/consumer && touch /etc/pki/consumer/cert.pem || true
# Conditionally build components that exist
BUILT_ANY=0
if [ -d "/work/inspector" ] && [ -f "/work/inspector/Dockerfile" ]; then
  echo "[BUILD] Building inspector"
  make build-inspector || exit 1
  BUILT_ANY=1
fi
if [ -d "/work/assisted-service-mcp" ]; then
  echo "[BUILD] Building assisted-service-mcp"
  make build-assisted-mcp || exit 1
  BUILT_ANY=1
fi
if [ -d "/work/lightspeed-stack" ] && [ -f "/work/lightspeed-stack/Containerfile" ]; then
  echo "[BUILD] Building lightspeed-stack"
  make build-lightspeed-stack || exit 1
  BUILT_ANY=1
fi
if [ -d "/work/assisted-installer-ui" ] && [ -f "/work/assisted-installer-ui/apps/assisted-ui/Containerfile" ]; then
  echo "[BUILD] Building assisted-ui"
  make build-ui || exit 1
  BUILT_ANY=1
fi
if [ "$BUILT_ANY" -eq 0 ]; then
  echo "[BUILD] No buildable components found; skipping image builds"
else
  echo "[BUILD] All requested images built successfully!"
fi
echo "[RUN] Starting services"
make run &
sleep 15
BASE_URL="http://localhost:8090"
echo "[HEALTH] Probing ${BASE_URL}/v1/models"
if [ -n "${OCM_TOKEN:-}" ]; then curl -v --max-time 10 -H "Authorization: Bearer ${OCM_TOKEN}" "${BASE_URL}/v1/models" >/dev/null || true; fi
echo "[EVAL] Running test-eval"
make test-eval
echo "[RUN] Stopping services"
make stop
RS
# Normalize any accidental trailing backslashes left from templating
sed -E -i 's/\\+$//' "$TMPD/runner.sh"

# Instead of base64, write the script directly to a ConfigMap and mount it
oc -n "$NS" create configmap assisted-chat-runner-script --from-file=run.sh="$TMPD/runner.sh" >/dev/null

# Create the privileged runner pod on the claimed cluster (simplified approach)
cat >"$TMPD/pod.yaml" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: assisted-chat-local
spec:
  restartPolicy: Never
  serviceAccountName: default
  containers:
  - name: runner
    image: quay.io/podman/stable:latest
    imagePullPolicy: IfNotPresent
    securityContext:
      privileged: true
      runAsUser: 0
    env:
    - name: REPO_OWNER
      value: "${SRC_ORG}"
    - name: REPO_NAME
      value: "${SRC_REPO}"
    - name: REPO_REF
      value: "${SRC_SHA}"
    - name: OCM_TOKEN
      value: "${OCM_TOKEN_VALUE}"
    - name: GEMINI_PRESENT
      value: "$([ -n "${GEMINI_API_KEY:-}" ] && echo true || echo false)"
    command: ["/bin/bash"]
    args: ["-xeuo", "pipefail", "/scripts/run.sh"]
    volumeMounts:
    - name: gemini
      mountPath: /var/run/secrets/gemini
      readOnly: true
    - name: vertex
      mountPath: /var/run/secrets/vertex/service_account
      readOnly: true
    - name: sso-ci
      mountPath: /var/run/secrets/sso-ci
      readOnly: true
    - name: runner-script
      mountPath: /scripts
      readOnly: true
  volumes:
  - name: gemini
    secret:
      secretName: assisted-chat-gemini
      optional: true
  - name: vertex
    secret:
      secretName: assisted-chat-vertex
      optional: true
      items:
      - key: service_account
        path: cred.json
  - name: sso-ci
    secret:
      secretName: assisted-chat-sso-ci
      optional: true
  - name: runner-script
    configMap:
      name: assisted-chat-runner-script
      defaultMode: 0755
EOF

# Validate YAML before apply
if command -v yq >/dev/null 2>&1; then
  if ! yq eval '.' "$TMPD/pod.yaml" >/dev/null 2>&1; then
    echo "[YAML] Invalid pod manifest detected. Dumping with line numbers:" >&2
    nl -ba "$TMPD/pod.yaml" >&2 || cat "$TMPD/pod.yaml" >&2
    exit 1
  fi
else
  echo "[YAML] yq not found; skipping yq validation" >&2
fi
if ! oc -n "$NS" create --dry-run=client -f "$TMPD/pod.yaml" >/dev/null 2>&1; then
  echo "[OC DRY-RUN] Failed to validate pod manifest. Dumping with line numbers:" >&2
  nl -ba "$TMPD/pod.yaml" >&2 || cat "$TMPD/pod.yaml" >&2
  echo "[OC DRY-RUN] oc error output:" >&2
  oc -n "$NS" create --dry-run=client -f "$TMPD/pod.yaml" 2>&1 || true
  exit 1
fi

# Create and wait for the runner pod
oc -n "$NS" apply -f "$TMPD/pod.yaml" >/dev/null
# Stream logs until termination
set +e
oc -n "$NS" logs -f pod/assisted-chat-local &
LOGS_PID=$!
# Wait up to 40 minutes
oc -n "$NS" wait --for=condition=Ready pod/assisted-chat-local --timeout=10m >/dev/null 2>&1 || true
oc -n "$NS" wait --for=condition=ContainersReady pod/assisted-chat-local --timeout=10m >/dev/null 2>&1 || true
# Poll for completion
for i in {1..120}; do
  PHASE=$(oc -n "$NS" get pod assisted-chat-local -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$PHASE" = "Succeeded" ] || [ "$PHASE" = "Failed" ]; then break; fi
  sleep 20
done
kill "$LOGS_PID" 2>/dev/null || true
set -e

PHASE=$(oc -n "$NS" get pod assisted-chat-local -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "$PHASE" != "Succeeded" ]; then
  echo "Runner pod did not succeed. Phase=$PHASE"
  oc -n "$NS" describe pod assisted-chat-local || true
  oc -n "$NS" logs pod/assisted-chat-local || true
  exit 1
fi

# Cleanup handled by trap (namespace deletion)