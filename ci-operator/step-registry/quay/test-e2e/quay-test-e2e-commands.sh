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
# results.json is a structured Prow artifact from the Playwright json reporter (ref quay/quay#7049)
export PLAYWRIGHT_JSON_OUTPUT_NAME="${ARTIFACT_DIR}/results.json"
export PLAYWRIGHT_BROWSERS_PATH=/opt/playwright
export QUAY_USERNAME
export QUAY_PASSWORD
export CI=true

# Mailpit HTTP API base URL for email-dependent specs. utils/mailpit.ts reads
# process.env.MAILPIT_API_URL (NOT MAILPIT_API), so the var name must match or the
# suite falls back to http://localhost:8025 and reports "Mailpit NOT available".
# Written by the quay-deploy-mailpit step. Left unset when mailing is off.
if [[ -s "${SHARED_DIR}/mailpit_api" ]]; then
  MAILPIT_API_URL=$(cat "${SHARED_DIR}/mailpit_api")
  export MAILPIT_API_URL
  echo "MAILPIT_API_URL=${MAILPIT_API_URL}"
else
  echo "No mailpit_api in SHARED_DIR; email-dependent specs may skip or fail"
fi

# The Playwright suite is cloned from PLAYWRIGHT_GIT_REPO at a ref resolved in this
# order (first match wins):
#   1. PLAYWRIGHT_GIT_BRANCH        - explicit override from the ci-operator config.
#   2. ${SHARED_DIR}/playwright_git_ref - commit auto-derived by the deploy step from
#      the deployed Quay app image's source-commit label, so the suite is version-
#      matched to the product with no manual upkeep.
#   3. PLAYWRIGHT_GIT_FALLBACK_BRANCH - last-resort branch so the run still executes
#      (with a warning) instead of hard-failing when nothing else is available.
# PLAYWRIGHT_GIT_REPO stays required. The resolved ref may be a branch, tag, or commit
# SHA; clone_playwright_sources handles each.
PLAYWRIGHT_GIT_REPO="${PLAYWRIGHT_GIT_REPO:-}"
PLAYWRIGHT_GIT_BRANCH="${PLAYWRIGHT_GIT_BRANCH:-}"
PLAYWRIGHT_GIT_FALLBACK_BRANCH="${PLAYWRIGHT_GIT_FALLBACK_BRANCH:-redhat-3.18}"
if [[ -z "${PLAYWRIGHT_GIT_REPO}" ]]; then
  echo "ERROR: PLAYWRIGHT_GIT_REPO must be set" >&2
  exit 1
fi
if [[ -n "${PLAYWRIGHT_GIT_BRANCH}" ]]; then
  PLAYWRIGHT_GIT_REF="${PLAYWRIGHT_GIT_BRANCH}"
  echo "Using explicitly configured Playwright ref: ${PLAYWRIGHT_GIT_REF}"
elif [[ -s "${SHARED_DIR}/playwright_git_ref" ]]; then
  PLAYWRIGHT_GIT_REF="$(cat "${SHARED_DIR}/playwright_git_ref")"
  echo "Using Playwright ref auto-derived from the deployed image: ${PLAYWRIGHT_GIT_REF}"
else
  PLAYWRIGHT_GIT_REF="${PLAYWRIGHT_GIT_FALLBACK_BRANCH}"
  echo "WARNING: no explicit PLAYWRIGHT_GIT_BRANCH and no derived ref in SHARED_DIR;" >&2
  echo "         falling back to branch ${PLAYWRIGHT_GIT_REF}" >&2
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

CLONE_DIR="/tmp/quay-playwright-src"
echo "Cloning Playwright tests from ${PLAYWRIGHT_GIT_REPO} (ref ${PLAYWRIGHT_GIT_REF})"
clone_playwright_sources "${PLAYWRIGHT_GIT_REPO}" "${PLAYWRIGHT_GIT_REF}" "${CLONE_DIR}"
PLAYWRIGHT_WORKDIR="${CLONE_DIR}/web"
if [[ ! -d "${PLAYWRIGHT_WORKDIR}" ]]; then
  echo "ERROR: cloned sources have no web/ directory at ${PLAYWRIGHT_WORKDIR}" >&2
  exit 1
fi

echo "Installing npm dependencies for Playwright ref ${PLAYWRIGHT_GIT_REF}..."
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
  # Playwright records each skip reason as <property name="skip" value="..."> but
  # leaves the <skipped> element empty. Prow's junit lens shows a skip reason only
  # from the skipped element's message attribute, so copy the property value there.
  # python3 is not in the ubi9 nodejs-minimal runner image, so this uses awk.
  # Best-effort: never fail the EXIT trap.
  for xml in "${ARTIFACT_DIR}"/junit_*.xml; do
    [[ -f "${xml}" ]] || continue
    awk '
      /<testcase/ { hasskip = 0; skipval = "" }
      /<property name="skip" value="/ {
        v = $0
        sub(/^.*<property name="skip" value="/, "", v)
        sub(/">[ \t]*$/, "", v)
        hasskip = 1
        skipval = v
      }
      /^[ \t]*<skipped>[ \t]*$/ {
        if (hasskip) {
          match($0, /^[ \t]*/)
          indent = substr($0, 1, RLENGTH)
          print indent "<skipped message=\"" skipval "\">"
          hasskip = 0
          next
        }
      }
      { print }
    ' "${xml}" > "${xml}.tmp" && mv "${xml}.tmp" "${xml}" || rm -f "${xml}.tmp"
  done || true
  # A passing testcase with a -retry<N>/ ATTACHMENT in <system-out> was retried; Prow's
  # junit lens flags flaky only when a name+classname has both a passed and a failed entry,
  # so tag it flaky and emit a matching failed twin. Idempotent; awk only.
  for xml in "${ARTIFACT_DIR}"/junit_*.xml; do
    [[ -f "${xml}" ]] || continue
    awk '
      /<testcase/ && !buffering {
        buffering = 1; n = 0
        isretry = 0; hasfailure = 0; hasflaky = 0; hasprops = 0; inserted = 0
        insysout = 0; tag = ""; tagdone = 0; tagendidx = 0
      }
      buffering {
        buf[n++] = $0
        if (!tagdone) { tag = (tag == "" ? $0 : tag " " $0); if ($0 ~ />/) { tagdone = 1; tagendidx = n - 1 } }
        if ($0 ~ /<system-out/) insysout = 1
        if (insysout && $0 ~ /\[\[ATTACHMENT\|.*-retry[0-9]+\//) isretry = 1
        if ($0 ~ /<\/system-out>/) insysout = 0
        if ($0 ~ /<failure/ || $0 ~ /<error/) hasfailure = 1
        if ($0 ~ /<property name="flaky"/) hasflaky = 1
        if ($0 ~ /<properties>/) hasprops = 1
        if ($0 ~ /<\/testcase>/) {
          addflaky = (isretry && !hasfailure && !hasflaky)
          if (addflaky && hasprops) {
            for (i = 0; i < n; i++) {
              if (!inserted && buf[i] ~ /<\/properties>/) {
                print "<property name=\"flaky\" value=\"true\"/>"
                inserted = 1
              }
              print buf[i]
            }
          } else if (addflaky) {
            for (i = 0; i <= tagendidx; i++) print buf[i]
            print "<properties>"
            print "<property name=\"flaky\" value=\"true\"/>"
            print "</properties>"
            for (i = tagendidx + 1; i < n; i++) print buf[i]
          } else {
            for (i = 0; i < n; i++) print buf[i]
          }
          if (addflaky) {
            name = ""; cls = ""
            if (match(tag, /[ \t]name="[^"]*"/)) {
              name = substr(tag, RSTART, RLENGTH); sub(/^[ \t]name="/, "", name); sub(/"$/, "", name)
            }
            if (match(tag, /[ \t]classname="[^"]*"/)) {
              cls = substr(tag, RSTART, RLENGTH); sub(/^[ \t]classname="/, "", cls); sub(/"$/, "", cls)
            }
            if (name != "" && cls != "")
              print "<testcase name=\"" name "\" classname=\"" cls "\" time=\"0\"><failure message=\"flaky: passed on retry\"></failure></testcase>"
          }
          buffering = 0
        }
        next
      }
      { print }
    ' "${xml}" > "${xml}.tmp" && mv "${xml}.tmp" "${xml}" || rm -f "${xml}.tmp"
  done || true
  cp -r "${src}"/playwright-report/* "${ARTIFACT_DIR}/" 2>/dev/null || true
  # Prow's html lens renders any artifact matching custom-link-*.html inline near
  # the top of the Spyglass job page. The Playwright HTML report copied above only
  # shows up buried in the artifact tree, so surface a direct link to it. Compose
  # the GCS URL the same way hypershift-analyze-e2e-failure does. Only write the
  # link when index.html actually landed so it is never dead; default every CI var
  # with :- so a missing var in a local run cannot abort this EXIT trap.
  if [[ -f "${ARTIFACT_DIR}/index.html" ]]; then
    local gcs_base="https://gcs.ci.openshift.org/gcs/test-platform-results"
    local gcs_path
    if [[ "${JOB_TYPE:-}" == "presubmit" && -n "${PULL_NUMBER:-}" ]]; then
      gcs_path="pr-logs/pull/${REPO_OWNER:-}_${REPO_NAME:-}/${PULL_NUMBER:-}/${JOB_NAME:-}/${BUILD_ID:-}"
    else
      gcs_path="logs/${JOB_NAME:-}/${BUILD_ID:-}"
    fi
    local report_base="${gcs_base}/${gcs_path}/artifacts/${JOB_NAME_SAFE:-}/quay-test-e2e/artifacts"
    cat > "${ARTIFACT_DIR}/custom-link-playwright-report.html" << EOF || true
<html>
<head>
<title>Playwright report</title>
<style>
a { display:inline-block; padding:5px 20px; margin:10px; border:2px solid #4E9AF1; border-radius:1em; text-decoration:none; color:#FFFFFF !important; background-color:#4E9AF1; }
</style>
</head>
<body>
<a target="_blank" href="${report_base}/index.html">Playwright HTML report</a>
</body>
</html>
EOF
  else
    echo "No index.html in ${ARTIFACT_DIR}; skipping custom-link-playwright-report.html"
  fi
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

# Route DNS/connectivity readiness gate. The suite fires hundreds of rapid
# apiRequestContext calls with tight 5-10s timeouts; on a freshly provisioned
# cluster the test pod's resolver intermittently returns ENOTFOUND for the *.apps
# wildcard (and TCP/TLS is slow) until the record and resolver cache warm. Starting
# the run into a cold resolver is the top source of flakes/failures. Block until the
# route both resolves AND answers over HTTPS several times in a row before launching
# Playwright. Best-effort: warn and proceed on timeout so we never hard-fail here.
QUAY_HOST="${QUAY_ROUTE#*://}"; QUAY_HOST="${QUAY_HOST%%/*}"
echo "Waiting for Quay route DNS + HTTPS readiness..."
ready=0
for attempt in $(seq 1 60); do
  http_code="$(curl -sk -o /dev/null -m 10 -w '%{http_code}' "${QUAY_ROUTE}/api/v1/discovery" 2>/dev/null || echo 000)"
  if getent ahosts "${QUAY_HOST}" >/dev/null 2>&1 && [[ "${http_code}" != "000" ]]; then
    ready=$((ready + 1))
    echo "  readiness ${ready}/5 (attempt ${attempt}, http=${http_code})"
    [[ "${ready}" -ge 5 ]] && break
  else
    [[ "${ready}" -ne 0 ]] && echo "  readiness reset (attempt ${attempt}, http=${http_code})"
    ready=0
  fi
  sleep 5
done
if [[ "${ready}" -ge 5 ]]; then
  echo "Quay route is resolvable and responding; starting tests."
else
  echo "WARNING: Quay route did not reach stable DNS+HTTPS readiness in time; proceeding anyway" >&2
fi

# Tests excluded from the run come entirely from PLAYWRIGHT_GREP_INVERT, set in the
# ci-operator config (steps.env) for this test. Keeping the exclusion list in the
# config rather than hardcoding it here lets each variant tune what it quarantines
# without editing this shared step. The value is a JS regex matched against the full
# Playwright test title; see E2E_FAILURE_REPORT.md in the repo root for the rationale
# behind the current exclusions. When unset, the full suite runs.
PLAYWRIGHT_GREP_INVERT="${PLAYWRIGHT_GREP_INVERT:-}"
GREP_INVERT_ARGS=()
if [[ -n "${PLAYWRIGHT_GREP_INVERT}" ]]; then
  GREP_INVERT_ARGS=(--grep-invert "${PLAYWRIGHT_GREP_INVERT}")
  echo "Excluding tests matching: ${PLAYWRIGHT_GREP_INVERT}"
else
  echo "No PLAYWRIGHT_GREP_INVERT set; running the full suite."
fi

# Playwright parallelism. The suite's playwright.config.ts uses `workers: CI ? 4`.
# The @container tests each push a REAL image over the self-signed Quay route, and
# @feature:BUILD_SUPPORT tests drive virtual-builder builds; at 4 concurrent workers
# these heavy pushes/builds contend and intermittently exceed the 60s test timeout
# and the suite's tight per-call apiRequestContext timeouts (5s create-repo, 10s
# build-status), producing flaky timeouts even though the product is healthy (the
# same operations pass on retry). Cap concurrency to relieve that contention. The CLI
# --workers flag overrides the config value; override via PLAYWRIGHT_WORKERS if needed.
PLAYWRIGHT_WORKERS="${PLAYWRIGHT_WORKERS:-2}"

echo "Running Playwright e2e install tests from ${PLAYWRIGHT_WORKDIR} (ref ${PLAYWRIGHT_GIT_REF}, workers ${PLAYWRIGHT_WORKERS})..."
pushd "${PLAYWRIGHT_WORKDIR}"
npx playwright test \
  "${GREP_INVERT_ARGS[@]}" \
  --workers "${PLAYWRIGHT_WORKERS}" \
  --reporter=list,junit,html,json \
  2>&1 | tee "${ARTIFACT_DIR}/playwright-output.log"
popd
