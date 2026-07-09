#!/bin/bash

set -euo pipefail
set -x

NAMESPACE="quay-enterprise"
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

QUAY_ROUTE=$(cat "${SHARED_DIR}/quayroute")
if [[ -z "${QUAY_ROUTE}" ]]; then
  echo "ERROR: quayroute not found in SHARED_DIR" >&2
  exit 1
fi
echo "Quay route: ${QUAY_ROUTE}"

KEYCLOAK_ROUTE=$(cat "${SHARED_DIR}/keycloak_route")
if [[ -z "${KEYCLOAK_ROUTE}" ]]; then
  echo "ERROR: keycloak_route not found in SHARED_DIR" >&2
  exit 1
fi
echo "Keycloak route: ${KEYCLOAK_ROUTE}"

# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
$WAS_TRACING && set -x

export PLAYWRIGHT_BASE_URL="${QUAY_ROUTE}"
export REACT_QUAY_APP_API_URL="${QUAY_ROUTE}"
export QUAY_USERNAME
export QUAY_PASSWORD
export CI=true
export OPENSHIFT_CI=true

# Pod IP so WebhookReceiver URLs are reachable from Quay pods in the cluster
export WEBHOOK_HOST=$(hostname -i | awk '{print $1}')

# Trust the cluster ingress CA so Node.js fetch() validates route certs
oc extract cm/default-ingress-cert -n openshift-config-managed --to=/tmp/certs --confirm
export NODE_EXTRA_CA_CERTS=/tmp/certs/ca-bundle.crt

# ---------------------------------------------------------------------------
# Clone quay/quay at the specified commit and install Playwright
# ---------------------------------------------------------------------------
echo "Cloning quay/quay at ${QUAY_SRC_COMMIT}..."
git init /tmp/quay
cd /tmp/quay
git fetch --depth 1 https://github.com/quay/quay.git "${QUAY_SRC_COMMIT}"
git checkout FETCH_HEAD

cd /tmp/quay/web

echo "Installing test dependencies..."
npm ci --ignore-scripts

echo "Installing Chromium browser..."
npx playwright install chromium

# Download pinned yq for YAML config merging
YQ_VERSION="v4.44.3"
YQ_ARCH="$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')"
curl -sSfL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}" -o /tmp/yq
chmod +x /tmp/yq

# Install CLI tools for container interop tests (regctl, oras, crane)
# npm global installs go to $HOME which is writable; binaries go to /tmp
npm install -g regctl || true
ORAS_VERSION="1.3.2"
curl -sSfL "https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/oras_${ORAS_VERSION}_linux_${YQ_ARCH}.tar.gz" \
  | tar -xz -C /tmp oras
CRANE_VERSION="0.20.3"
curl -sSfL "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" \
  | tar -xz -C /tmp crane
export PATH="/tmp:${PATH}"

# Mailpit API via Route (mailpit.ts reads MAILPIT_API_URL)
MAILPIT_ROUTE=$(cat "${SHARED_DIR}/mailpit_route")
export MAILPIT_API_URL="${MAILPIT_ROUTE}/api/v1"
echo "Mailpit API: ${MAILPIT_API_URL}"

echo "Waiting for Mailpit to be reachable..."
curl -skf --retry 30 --retry-delay 1 --retry-all-errors \
  "${MAILPIT_API_URL}/messages" > /dev/null
echo "Mailpit is ready"

function cleanup {
  echo "Merging blob reports into combined HTML + JUnit..."
  mkdir -p all-blob-reports
  find blob-results -name '*.zip' -exec cp {} all-blob-reports/ \; 2>/dev/null || true
  if [ "$(ls -A all-blob-reports 2>/dev/null)" ]; then
    PLAYWRIGHT_JUNIT_OUTPUT_NAME="${ARTIFACT_DIR}/junit_playwright.xml" \
      npx playwright merge-reports --reporter=html,junit all-blob-reports || true
  fi

  cp -r test-results/* "${ARTIFACT_DIR}/" 2>/dev/null || true
  cp -r playwright-report/* "${ARTIFACT_DIR}/" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helper: swap Quay auth config and restart
# ---------------------------------------------------------------------------
swap_quay_config() {
  local overlay_file="$1"
  echo "Swapping Quay config with overlay: ${overlay_file}"

  oc -n "${NAMESPACE}" get secret config-bundle-secret \
    -o jsonpath='{.data.config\.yaml}' | base64 -d > /tmp/current-config.yaml

  /tmp/yq eval-all 'select(fileIndex == 0) *+ select(fileIndex == 1)' \
    /tmp/current-config.yaml "${overlay_file}" > /tmp/merged-config.yaml

  oc -n "${NAMESPACE}" create secret generic config-bundle-secret \
    --from-file=config.yaml=/tmp/merged-config.yaml \
    --dry-run=client -o yaml | oc apply -f -

  QUAY_DEPLOY=$(oc -n "${NAMESPACE}" get deployment -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep 'quay-app' | head -n1)
  if [[ -z "${QUAY_DEPLOY}" ]]; then
    echo "ERROR: Could not find quay-app deployment" >&2
    return 1
  fi

  oc -n "${NAMESPACE}" rollout restart "deployment/${QUAY_DEPLOY}"
  oc -n "${NAMESPACE}" rollout status "deployment/${QUAY_DEPLOY}" --timeout=300s

  echo "Waiting for Quay to be healthy after config swap..."
  curl -skf --retry 60 --retry-delay 5 --retry-all-errors \
    "${QUAY_ROUTE}/health/instance" > /dev/null
  echo "Quay is healthy"
}

OVERALL_RESULT=0

# ---------------------------------------------------------------------------
# Phase 1: Database auth tests
# ---------------------------------------------------------------------------
echo "========================================="
echo "Phase 1: Database auth tests"
echo "========================================="

DB_GREP="--grep-invert @auth:OIDC|@auth:LDAP"
if [[ -n "${PLAYWRIGHT_GREP}" ]]; then
  DB_GREP="${DB_GREP} --grep ${PLAYWRIGHT_GREP}"
fi

PLAYWRIGHT_BLOB_OUTPUT_DIR=blob-results/db \
npx playwright test \
  ${DB_GREP} \
  --workers=4 \
  --reporter=blob \
  2>&1 | tee "${ARTIFACT_DIR}/playwright-db-output.log" || OVERALL_RESULT=1

# ---------------------------------------------------------------------------
# Phase 2: OIDC auth tests
# ---------------------------------------------------------------------------
echo "========================================="
echo "Phase 2: OIDC auth tests"
echo "========================================="

cat > /tmp/oidc-overlay.yaml <<OIDC_EOF
SOMEOIDC_LOGIN_CONFIG:
  SERVICE_NAME: "Keycloak"
  OIDC_SERVER: "${KEYCLOAK_ROUTE}/realms/quay/"
  CLIENT_ID: "quay-ui"
  LOGIN_SCOPES:
    - "openid"
    - "profile"
    - "email"
  DEBUGGING: true
  USE_PKCE: true
  PKCE_METHOD: "S256"
  PUBLIC_CLIENT: true
AUTHENTICATION_TYPE: OIDC
FEATURE_TEAM_SYNCING: true
FEATURE_NONSUPERUSER_TEAM_SYNCING_SETUP: true
SUPER_USERS:
  - admin
  - admin_oidc
GLOBAL_READONLY_SUPER_USERS:
  - readonly
  - readonly_oidc
OIDC_EOF

swap_quay_config /tmp/oidc-overlay.yaml

OIDC_GREP="--grep @auth:OIDC"
if [[ -n "${PLAYWRIGHT_GREP}" ]]; then
  OIDC_GREP="${OIDC_GREP} --grep ${PLAYWRIGHT_GREP}"
fi

PLAYWRIGHT_BLOB_OUTPUT_DIR=blob-results/oidc \
npx playwright test \
  ${OIDC_GREP} \
  --workers=4 \
  --reporter=blob \
  2>&1 | tee "${ARTIFACT_DIR}/playwright-oidc-output.log" || OVERALL_RESULT=1

# ---------------------------------------------------------------------------
# Phase 3: LDAP auth tests
# ---------------------------------------------------------------------------
echo "========================================="
echo "Phase 3: LDAP auth tests"
echo "========================================="

cat > /tmp/ldap-overlay.yaml <<'LDAP_EOF'
AUTHENTICATION_TYPE: LDAP
FEATURE_TEAM_SYNCING: true
FEATURE_NONSUPERUSER_TEAM_SYNCING_SETUP: true
STAGGER_WORKERS: false
LDAP_ADMIN_DN: cn=Directory Manager
LDAP_ADMIN_PASSWD: admin
LDAP_ALLOW_INSECURE_FALLBACK: true
LDAP_BASE_DN:
  - dc=example
  - dc=org
LDAP_EMAIL_ATTR: mail
LDAP_MEMBEROF_ATTR: quayMemberOf
LDAP_UID_ATTR: uid
LDAP_URI: ldap://ldap.quay-enterprise.svc:3389
LDAP_USER_RDN:
  - ou=users
SUPER_USERS:
  - admin
  - admin_ldap
GLOBAL_READONLY_SUPER_USERS:
  - readonly
  - readonly_ldap
LDAP_EOF

swap_quay_config /tmp/ldap-overlay.yaml

LDAP_GREP="--grep @auth:LDAP"
if [[ -n "${PLAYWRIGHT_GREP}" ]]; then
  LDAP_GREP="${LDAP_GREP} --grep ${PLAYWRIGHT_GREP}"
fi

PLAYWRIGHT_BLOB_OUTPUT_DIR=blob-results/ldap \
npx playwright test \
  ${LDAP_GREP} \
  --workers=4 \
  --reporter=blob \
  2>&1 | tee "${ARTIFACT_DIR}/playwright-ldap-output.log" || OVERALL_RESULT=1

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
if [[ "${OVERALL_RESULT}" -ne 0 ]]; then
  echo "One or more test phases failed"
  exit 1
fi
echo "All test phases passed"
