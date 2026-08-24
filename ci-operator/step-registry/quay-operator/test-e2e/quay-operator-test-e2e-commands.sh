#!/bin/bash

set -euo pipefail
set -x

ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "${ARTIFACT_DIR}"

# Read the Quay route written by the deploy step
QUAY_ROUTE=$(cat "${SHARED_DIR}/quayroute")
if [[ -z "${QUAY_ROUTE}" ]]; then
  echo "ERROR: quayroute not found in SHARED_DIR" >&2
  exit 1
fi
echo "Quay route: ${QUAY_ROUTE}"

# Read credentials
# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
QUAY_USERNAME=$(cat /var/run/quay-qe-quay-secret/username)
QUAY_PASSWORD=$(cat /var/run/quay-qe-quay-secret/password)
$WAS_TRACING && set -x

# Configure Playwright environment
# PLAYWRIGHT_BASE_URL: browser navigation URL (Quay UI)
# REACT_QUAY_APP_API_URL: backend API URL (same as UI on OCP)
export PLAYWRIGHT_BASE_URL="${QUAY_ROUTE}"
export REACT_QUAY_APP_API_URL="${QUAY_ROUTE}"
export PLAYWRIGHT_JUNIT_OUTPUT_NAME="${ARTIFACT_DIR}/junit_playwright.xml"
export PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
export QUAY_USERNAME
export QUAY_PASSWORD
export CI=true

# Mailpit HTTP API base URL for email-dependent specs. utils/mailpit.ts reads
# process.env.MAILPIT_API_URL (NOT MAILPIT_API), so the var name must match or the
# suite falls back to http://localhost:8025 and reports "Mailpit NOT available".
# Written by the quay-operator-deploy-mailpit step. Left unset when mailing is off.
if [[ -s "${SHARED_DIR}/mailpit_api" ]]; then
  MAILPIT_API_URL=$(cat "${SHARED_DIR}/mailpit_api")
  export MAILPIT_API_URL
  echo "MAILPIT_API_URL=${MAILPIT_API_URL}"
else
  echo "No mailpit_api in SHARED_DIR; email-dependent specs may skip or fail"
fi

PLAYWRIGHT_WORKDIR="/go/src/github.com/quay/quay/web"
PLAYWRIGHT_GIT_REPO="${PLAYWRIGHT_GIT_REPO:-https://github.com/quay/quay.git}"

# Gangway / rehearsal override wins over PLAYWRIGHT_GIT_BRANCH.
if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_PLAYWRIGHT_GIT_BRANCH:-}" ]]; then
  PLAYWRIGHT_GIT_BRANCH="${MULTISTAGE_PARAM_OVERRIDE_PLAYWRIGHT_GIT_BRANCH}"
fi

clone_playwright_sources() {
  local repo="$1"
  local ref="$2"
  local dest="$3"

  rm -rf "${dest}"
  mkdir -p "${dest}"
  export GIT_TERMINAL_PROMPT=0

  if command -v git >/dev/null 2>&1; then
    # A 40-char hex ref is a commit SHA. `git clone --branch` only accepts a
    # branch or tag name, so for a SHA we init + shallow-fetch that exact commit
    # and check it out (GitHub allows fetching any reachable SHA). This is what
    # lets us version-match the tests to the deployed image's build commit.
    if [[ "${ref}" =~ ^[0-9a-f]{40}$ ]]; then
      git init -q "${dest}"
      git -C "${dest}" remote add origin "${repo}"
      git -C "${dest}" fetch --depth 1 origin "${ref}"
      git -C "${dest}" checkout -q FETCH_HEAD
    else
      git clone --depth 1 --branch "${ref}" "${repo}" "${dest}"
    fi
    return
  fi

  echo "git is not installed; downloading archive for ${ref}..."
  local archive
  archive="$(mktemp /tmp/quay-src.XXXXXX.tar.gz)"
  local base="${repo%.git}"
  # GitHub serves /archive/<sha>.tar.gz for a commit as well as branch/tag names.
  if curl -fsSL "${base}/archive/${ref}.tar.gz" -o "${archive}"; then
    :
  elif curl -fsSL "${base}/archive/refs/heads/${ref}.tar.gz" -o "${archive}"; then
    :
  elif curl -fsSL "${base}/archive/refs/tags/${ref}.tar.gz" -o "${archive}"; then
    :
  else
    echo "ERROR: failed to download ${repo} at ${ref}" >&2
    rm -f "${archive}"
    exit 1
  fi
  tar -xzf "${archive}" --strip-components=1 -C "${dest}"
  rm -f "${archive}"
}

# Default: use tests and browsers baked into quay-playwright-runner (same git
# ref as the image build). Clone only when PLAYWRIGHT_GIT_BRANCH is set.
if [[ -n "${PLAYWRIGHT_GIT_BRANCH:-}" ]]; then
  CLONE_DIR="/tmp/quay-playwright-src"
  echo "Cloning Playwright tests from ${PLAYWRIGHT_GIT_REPO} (branch ${PLAYWRIGHT_GIT_BRANCH})"
  clone_playwright_sources "${PLAYWRIGHT_GIT_REPO}" "${PLAYWRIGHT_GIT_BRANCH}" "${CLONE_DIR}"
  PLAYWRIGHT_WORKDIR="${CLONE_DIR}/web"
  if [[ ! -d "${PLAYWRIGHT_WORKDIR}" ]]; then
    echo "ERROR: cloned sources have no web/ directory at ${PLAYWRIGHT_WORKDIR}" >&2
    exit 1
  fi

  echo "Installing npm dependencies for Playwright branch ${PLAYWRIGHT_GIT_BRANCH}..."
  pushd "${PLAYWRIGHT_WORKDIR}"
  npm ci

  # Image browsers live in /opt/playwright as root. Test pods cannot write there.
  IMAGE_BROWSERS=/opt/playwright
  if [[ -d "${IMAGE_BROWSERS}" && -w "${IMAGE_BROWSERS}" ]]; then
    export PLAYWRIGHT_BROWSERS_PATH="${IMAGE_BROWSERS}"
  else
    export PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright-browsers
    mkdir -p "${PLAYWRIGHT_BROWSERS_PATH}"
    if [[ -d "${IMAGE_BROWSERS}" ]]; then
      echo "Seeding writable browser cache from ${IMAGE_BROWSERS}..."
      cp -a "${IMAGE_BROWSERS}/." "${PLAYWRIGHT_BROWSERS_PATH}/" || true
    fi
  fi
  echo "PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH}"
  npx playwright install chromium
  popd
else
  echo "Using Playwright tests from image at ${PLAYWRIGHT_WORKDIR} (PLAYWRIGHT_GIT_BRANCH unset)"
  if [[ ! -d "${PLAYWRIGHT_WORKDIR}" ]]; then
    echo "ERROR: image is missing ${PLAYWRIGHT_WORKDIR}" >&2
    exit 1
  fi
fi

# Capture virtual-builder diagnostics from the TARGET cluster. Playwright build
# specs only see the API build object (which stays "build-scheduled" with no
# error), so the real cause lives in the build manager + the ephemeral builder
# pod in the virtual-builders namespace. This step has `cli: latest` and the
# target-cluster KUBECONFIG, so gather that state into ARTIFACT_DIR every run.
# All commands are best-effort (|| true) so they never fail the step.
function gatherBuilderDiagnostics {
  local ns="${QUAYNAMESPACE:-quay-enterprise}"
  local bns="virtual-builders"
  local out="${ARTIFACT_DIR}/builder-diagnostics"
  command -v oc >/dev/null 2>&1 || return 0
  oc whoami >/dev/null 2>&1 || return 0
  echo "Gathering virtual-builder diagnostics into ${out}..."
  mkdir -p "${out}"
  oc get pods -n "${bns}" -o wide                       > "${out}/virtual-builders-pods.txt"     2>&1 || true
  oc get events -n "${bns}" --sort-by=.lastTimestamp    > "${out}/virtual-builders-events.txt"   2>&1 || true
  oc describe pods -n "${bns}"                           > "${out}/virtual-builders-describe.txt" 2>&1 || true
  oc get all -n "${bns}" -o wide                         > "${out}/virtual-builders-all.txt"      2>&1 || true
  # Build manager runs inside the quay-app pods; keep only buildman/executor lines.
  oc logs -n "${ns}" -l quay-component=quay-app -c quay-app --tail=5000 2>/dev/null \
    | grep -iE 'buildman|build manager|executor|ephemeral|register|build token|kubernetes|traceback|error' \
    > "${out}/quay-app-buildman.log" 2>&1 || true
}

function copyArtifacts {
  echo "Copying test artifacts..."
  local src="${PLAYWRIGHT_WORKDIR:-.}"
  cp -r "${src}"/test-results/* "${ARTIFACT_DIR}/" 2>/dev/null || true
  # Rename JUnit reports with junit_ prefix for Prow
  for file in "${ARTIFACT_DIR}"/*.xml; do
    if [[ -f "${file}" ]] && [[ ! "$(basename "${file}")" =~ ^junit_ ]]; then
      mv "${file}" "${ARTIFACT_DIR}/junit_$(basename "${file}")"
    fi
  done
  cp -r "${src}"/playwright-report/* "${ARTIFACT_DIR}/" 2>/dev/null || true
  gatherBuilderDiagnostics || true
}
trap copyArtifacts EXIT

# Test users (admin/testuser/readonly) are created by Playwright's global-setup.ts,
# exactly as in upstream Quay CI (.github/workflows/ci-web.yaml). With FEATURE_MAILING
# on it also email-verifies them via Mailpit (clearInbox → createUser →
# waitForConfirmationLink). We intentionally do NOT pre-create users here: doing so
# fires the confirmation email before global-setup clears the inbox, so the link is
# never found and every user hits 403 needsEmailVerification.

# IPI cluster ingress certs are not in Node's trust store. global-setup.ts uses
# Node fetch() for GET ${API_URL}/config (not Playwright request, which has
# ignoreHTTPSErrors). Without this, config fetch throws and smoke tests never run.
export NODE_TLS_REJECT_UNAUTHORIZED=0

# The @container tests drive Go registry CLIs (regctl/crane/oras), which do NOT
# honor NODE_TLS_REJECT_UNAUTHORIZED. crane/oras get --insecure, but regctl's
# `tag ls` (cli-interop spec) has no insecure flag and rejects the self-signed
# Quay route. The rootCA that signs the route is bundled into ssl.cert
# (provisioning-tls appends rootCA.pem). Point Go's x509 at a combined store
# (system CAs + that rootCA) via SSL_CERT_FILE so regctl trusts the route while
# public pulls (quay.io busybox) still verify against the system bundle.
if [[ -s "${SHARED_DIR}/ssl.cert" ]]; then
  COMBINED_CA=/tmp/combined-ca.crt
  if [[ -s /etc/pki/tls/certs/ca-bundle.crt ]]; then
    cat /etc/pki/tls/certs/ca-bundle.crt "${SHARED_DIR}/ssl.cert" > "${COMBINED_CA}"
  else
    cp "${SHARED_DIR}/ssl.cert" "${COMBINED_CA}"
  fi
  export SSL_CERT_FILE="${COMBINED_CA}"
  echo "SSL_CERT_FILE=${SSL_CERT_FILE}"
fi

# Tests excluded from the run. Beyond unsupported auth backends (OIDC/LDAP), this
# quarantines tests tracking known product bugs and UI/version gaps that no Quay#
# NOTE: the primary defense against version skew is version-matching the tests to
# the deployed image's build commit via PLAYWRIGHT_GIT_BRANCH (set in the config to
# the same source ref as the pinned catalog). When that clone succeeds, the skew
# entries below simply do not exist in the checked-out suite and these grep-invert
# fragments no-op. They remain only as a safety net for when the run falls back to
# the image-baked tests (PLAYWRIGHT_GIT_BRANCH unset / clone failed).
BASE_GREP_INVERT='@auth:OIDC|@auth:LDAP'

# JS-regex fragments matched against the full Playwright test title.
QUARANTINE=(
  # Cosign .sig cascade on delete/retarget & autoprune — version skew: the cascade
  # backend (data/model/oci/tag.py) and these specs both landed on redhat-3.18 in
  # PROJQUAY-12551 (2026-08-07), AFTER the deployed catalog build (2026-07-30), so
  # the deployed image lacks the feature. Version-matching the tests removes these;
  # the fragments are a fallback for baked-HEAD runs. PROJQUAY-11682.
  'deleting subject image tag cascades to cosign \.sig tag'
  'deleting one alias keeps cosign \.sig while another alias remains'
  'retargeting last alias cascades cosign \.sig for displaced digest'
  'tag-count pruning excludes cosign \.sig tags and cascades on prune'
  'creation-date pruning does not age-prune cosign \.sig tags'
  # Quota-notification specs (org + user). NOT version skew: these specs and the
  # quota/notif UI are byte-identical at the pinned test ref and at HEAD, so
  # version-matching does not change them. They fail on an ENVIRONMENT gap (the
  # notification email path / feature enablement), which the deploy now addresses
  # via mailpit + FEATURE_MAILING + FEATURE_QUOTA_NOTIFICATIONS. Kept quarantined
  # until a real run confirms delivery; drop the passing ones then.
  'create and delete namespace notification logs render descriptions'
  'deleting quota removes all namespace notification configs'
  'email notification fires on quota threshold crossing'
  'can create a webhook notification, verify in list, test it, and delete it'
  'can create an email notification'
  'can create a Slack notification'
  'can create a Quay notification with team recipient'
  'Quay notification — submit disabled without recipient'
  # Repositories list domainRoute link — duplicated /repository/ path. PROJQUAY-11202.
  'tag link stays correct from /repository/\.\.\./testrepository\.\.\. path'
)

GREP_INVERT_DEFAULT="${BASE_GREP_INVERT}"
for q in "${QUARANTINE[@]}"; do GREP_INVERT_DEFAULT="${GREP_INVERT_DEFAULT}|${q}"; done
PLAYWRIGHT_GREP_INVERT="${PLAYWRIGHT_GREP_INVERT:-${GREP_INVERT_DEFAULT}}"
echo "Excluding tests matching: ${PLAYWRIGHT_GREP_INVERT}"

echo "Running Playwright smoke tests from ${PLAYWRIGHT_WORKDIR} (branch ${PLAYWRIGHT_GIT_BRANCH:-image})..."
pushd "${PLAYWRIGHT_WORKDIR}"
npx playwright test \
  --grep-invert "${PLAYWRIGHT_GREP_INVERT}" \
  --reporter=junit,html \
  2>&1 | tee "${ARTIFACT_DIR}/playwright-output.log"
popd
