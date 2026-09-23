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

PLAYWRIGHT_USE_IMAGE_TESTS="${PLAYWRIGHT_USE_IMAGE_TESTS:-false}"
CLONE_DIR="/tmp/quay-playwright-src"
if [[ "${PLAYWRIGHT_USE_IMAGE_TESTS}" == "true" ]]; then
  # /app is root-owned in the runner image (USER 1001, arbitrary UID on OpenShift) and
  # Playwright writes test-results/ and playwright-report/ into its cwd, so run a copy.
  echo "PLAYWRIGHT_USE_IMAGE_TESTS=true: using the suite baked into the runner image at /app"
  rm -rf "${CLONE_DIR}"; mkdir -p "${CLONE_DIR}/web"
  cp -a /app/. "${CLONE_DIR}/web/"
  PLAYWRIGHT_WORKDIR="${CLONE_DIR}/web"
  PLAYWRIGHT_GIT_REF="image"
  pushd "${PLAYWRIGHT_WORKDIR}"
else
# Left at column 0 (not indented) so this branch stays a byte-for-byte diff of
# the pre-image-tests script.
# The Playwright suite is cloned from PLAYWRIGHT_GIT_REPO at a ref resolved in this
# order (first match wins):
#   1. PLAYWRIGHT_GIT_BRANCH        - explicit override from the ci-operator config.
#   2. ${SHARED_DIR}/playwright_git_ref - ref auto-derived by the deploy step from the
#      deployed Quay app image's version/release labels (the upstream vX.Y.Z tag when
#      one matches, otherwise the redhat-X.Y branch), so the suite is version-matched
#      to the product with no manual upkeep.
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
PLAYWRIGHT_REF_IS_DERIVED=false
if [[ -n "${PLAYWRIGHT_GIT_BRANCH}" ]]; then
  PLAYWRIGHT_GIT_REF="${PLAYWRIGHT_GIT_BRANCH}"
  echo "Using explicitly configured Playwright ref: ${PLAYWRIGHT_GIT_REF}"
elif [[ -s "${SHARED_DIR}/playwright_git_ref" ]]; then
  PLAYWRIGHT_GIT_REF="$(cat "${SHARED_DIR}/playwright_git_ref")"
  PLAYWRIGHT_REF_IS_DERIVED=true
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
      # The commit a product image was built from is not guaranteed to exist in
      # ${repo}; return non-zero so the caller can fall back to a branch rather
      # than failing the whole e2e run on an unfetchable derived ref.
      git -C "${dest}" fetch --depth 1 origin "${ref}" || return 1
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
    return 1
  fi
  tar -xzf "${archive}" --strip-components=1 -C "${dest}"
  rm -f "${archive}"
}

echo "Cloning Playwright tests from ${PLAYWRIGHT_GIT_REPO} (ref ${PLAYWRIGHT_GIT_REF})"
if ! clone_playwright_sources "${PLAYWRIGHT_GIT_REPO}" "${PLAYWRIGHT_GIT_REF}" "${CLONE_DIR}"; then
  if [[ "${PLAYWRIGHT_REF_IS_DERIVED}" != true ]]; then
    echo "ERROR: failed to clone ${PLAYWRIGHT_GIT_REPO} at ${PLAYWRIGHT_GIT_REF}" >&2
    exit 1
  fi
  echo "WARNING: derived ref ${PLAYWRIGHT_GIT_REF} is not present in ${PLAYWRIGHT_GIT_REPO};" >&2
  echo "         falling back to branch ${PLAYWRIGHT_GIT_FALLBACK_BRANCH}" >&2
  PLAYWRIGHT_GIT_REF="${PLAYWRIGHT_GIT_FALLBACK_BRANCH}"
  clone_playwright_sources "${PLAYWRIGHT_GIT_REPO}" "${PLAYWRIGHT_GIT_REF}" "${CLONE_DIR}"
fi
PLAYWRIGHT_WORKDIR="${CLONE_DIR}/web"
if [[ ! -d "${PLAYWRIGHT_WORKDIR}" ]]; then
  echo "ERROR: cloned sources have no web/ directory at ${PLAYWRIGHT_WORKDIR}" >&2
  exit 1
fi

echo "Installing npm dependencies for Playwright ref ${PLAYWRIGHT_GIT_REF}..."
pushd "${PLAYWRIGHT_WORKDIR}"
npm ci
fi

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

# Expose the in-cluster Jaeger query API to the Playwright suite. On a failed
# test the suite attaches server-spans.json -- the Jaeger spans for that test's
# own requests -- by GETting ${JAEGER_QUERY_URL}/api/traces/<traceId>. With the
# variable unset that collection silently no-ops, so it has to be set here.
#
# Port-forward, not the in-cluster Service DNS: this step's pod runs in the CI
# build farm, not in the target cluster, so jaeger.${ns}.svc is unreachable from
# it. The step has `cli: latest` and the target-cluster KUBECONFIG, which is the
# same mechanism the quay-gather-jaeger-traces post step already uses against
# this Service. 127.0.0.1 rather than localhost so Node's fetch cannot pick ::1,
# which the forward does not bind.
#
# Best-effort: if Jaeger was not deployed or the forward never answers, leave
# JAEGER_QUERY_URL UNSET. The suite treats that as "not collected" and records a
# reason, which is better than handing it a URL that quietly returns nothing.
function startJaegerPortForward {
  local ns="${QUAYNAMESPACE:-quay-enterprise}"
  # Drop any inherited value so the "unset" paths below cannot leave an
  # unverified URL in the suite's environment.
  unset JAEGER_QUERY_URL
  if [[ ! -f "${SHARED_DIR}/jaeger_deployed" ]]; then
    echo "Jaeger was not deployed; leaving JAEGER_QUERY_URL unset"
    return 0
  fi

  # The suite can run for hours and a single port-forward does not survive a
  # Jaeger pod restart or an idle drop, so supervise it: the keeper restarts oc
  # until it is asked to stop, and on TERM kills the forward it is currently
  # supervising.
  (
    pf=""
    trap '[[ -n "${pf}" ]] && kill "${pf}" 2>/dev/null; exit 0' TERM
    while true; do
      oc port-forward -n "${ns}" svc/jaeger 16686:16686 >> "${ARTIFACT_DIR}/jaeger-port-forward.log" 2>&1 &
      pf=$!
      wait "${pf}" || true
      sleep 5
    done
  ) &
  JAEGER_PF_PID=$!

  for _ in $(seq 1 12); do
    if curl -sf --connect-timeout 5 --max-time 10 "http://127.0.0.1:16686/api/services" -o /dev/null; then
      export JAEGER_QUERY_URL="http://127.0.0.1:16686"
      echo "JAEGER_QUERY_URL=${JAEGER_QUERY_URL}"
      return 0
    fi
    sleep 5
  done

  echo "WARNING: Jaeger query API never became reachable; leaving JAEGER_QUERY_URL unset" >&2
  stopJaegerPortForward
}

function stopJaegerPortForward {
  [[ -n "${JAEGER_PF_PID:-}" ]] || return 0
  kill "${JAEGER_PF_PID}" 2>/dev/null || true
  wait "${JAEGER_PF_PID}" 2>/dev/null || true
  JAEGER_PF_PID=""
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
    local gcs_base="https://gcs.ci.openshift.org/gcs/test-platform-results-public"
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
trap 'copyArtifacts; stopJaegerPortForward' EXIT

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

# Route preflight gate. The suite fires hundreds of rapid apiRequestContext calls
# with tight 5-10s timeouts; on a freshly provisioned cluster the test pod's resolver
# intermittently returns ENOTFOUND for the *.apps wildcard (and TCP/TLS is slow) until
# the record and resolver cache warm, and the route happily answers 404/503 from the
# router while quay-app is still starting. Starting the run into either is the top
# source of mass failures, so require a genuinely healthy endpoint -- DNS answer,
# successful curl, HTTP 200, and a discovery-shaped JSON body -- for several samples
# in a row, and fail the step on the deadline instead of running the suite. One
# preflight JUnit case then reports the not-ready environment as a single clear
# failure rather than hundreds of test failures.
# A real quayroute is scheme+host with no port, but strip one anyway so getent always
# gets a bare name -- that also lets a local dry run point the gate at a host:port stub.
QUAY_HOST="${QUAY_ROUTE#*://}"; QUAY_HOST="${QUAY_HOST%%/*}"; QUAY_HOST="${QUAY_HOST%%:*}"
DISCOVERY_URL="${QUAY_ROUTE}/api/v1/discovery"
PREFLIGHT_DEADLINE_SECONDS=300
PREFLIGHT_REQUIRED_SAMPLES=5
PREFLIGHT_BODY=/tmp/quay-discovery-body.json
READINESS_LOG="${ARTIFACT_DIR}/readiness.jsonl"

function xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e "s/'/\&apos;/g" -e 's/"/\&quot;/g'
}

# One preflight sample against the discovery endpoint. Appends a JSON line to
# READINESS_LOG (timestamp, DNS answers, curl exit, HTTP status, curl's
# dns/connect/tls/ttfb timings) and sets PROBE_CLASS to one of
# ok | dns | transport | http | app-contract, with a human-readable PROBE_DETAIL.
function probe_route() {
  local attempt="$1"
  local ts dns curl_exit metrics http_code t_dns t_conn t_tls t_ttfb

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # getent exits 2 when the name does not resolve; under set -e/pipefail that would
  # abort the step, and an empty answer is exactly the dns failure we want to record.
  dns="$(getent ahosts "${QUAY_HOST}" 2>/dev/null | awk '{print $1}' | sort -u | paste -sd, -)" || dns=""

  # LC_ALL=C keeps curl's -w timings dot-decimal so the JSONL stays valid JSON.
  curl_exit=0
  metrics="$(LC_ALL=C curl -sk -m 10 -o "${PREFLIGHT_BODY}" \
    -w '%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer}' \
    "${DISCOVERY_URL}" 2>/dev/null)" || curl_exit=$?
  read -r http_code t_dns t_conn t_tls t_ttfb <<<"${metrics:-000 0 0 0 0}"

  if [[ -z "${dns}" || "${curl_exit}" -eq 6 ]]; then
    PROBE_CLASS=dns
    PROBE_DETAIL="${QUAY_HOST} did not resolve (curl exit ${curl_exit})"
  elif [[ "${curl_exit}" -ne 0 ]]; then
    PROBE_CLASS=transport
    PROBE_DETAIL="curl exit ${curl_exit} talking to ${DISCOVERY_URL}"
  elif [[ "${http_code}" != "200" ]]; then
    PROBE_CLASS=http
    PROBE_DETAIL="${DISCOVERY_URL} answered HTTP ${http_code}, want 200"
  # The runner is a nodejs image (it runs the Playwright suite), so node is the
  # available JSON parser here; python3 and jq are not in ubi9 nodejs-minimal.
  # Quay's swagger_route_data() always emits a non-empty top-level "paths" object,
  # so its absence means something other than Quay answered 200.
  elif ! node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const p=d&&d.paths;if(!p||typeof p!=="object"||Array.isArray(p)||Object.keys(p).length===0)process.exit(1)' \
      "${PREFLIGHT_BODY}" >/dev/null 2>&1; then
    PROBE_CLASS=app-contract
    PROBE_DETAIL="HTTP 200 from ${DISCOVERY_URL} but the body is not a discovery document (no non-empty JSON \"paths\")"
  else
    PROBE_CLASS=ok
    PROBE_DETAIL="HTTP 200 discovery document"
  fi

  printf '{"timestamp":"%s","attempt":%d,"dns":"%s","curl_exit":%d,"http_status":"%s","time_namelookup":%s,"time_connect":%s,"time_appconnect":%s,"time_starttransfer":%s,"class":"%s"}\n' \
    "${ts}" "${attempt}" "${dns}" "${curl_exit}" "${http_code}" \
    "${t_dns}" "${t_conn}" "${t_tls}" "${t_ttfb}" "${PROBE_CLASS}" >> "${READINESS_LOG}"
}

# Same lifecycle-JUnit shape the quay deploy steps write, so Sippy sees preflight as
# one more case in the quay-lifecycle suite.
function write_preflight_junit() {
  local failures="$1" duration="$2" message="$3"
  local tmp
  tmp="$(mktemp "${ARTIFACT_DIR}/junit_quay_preflight.xml.XXXXXX")"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    printf '<testsuite name="quay-lifecycle" tests="1" failures="%d" skipped="0" time="%d">\n' \
      "${failures}" "${duration}"
    printf '  <testcase name="[sig-quay] route preflight should report a healthy discovery endpoint" time="%d"' \
      "${duration}"
    if [[ "${failures}" -eq 1 ]]; then
      printf '>\n    <failure message="%s">%s</failure>\n  </testcase>\n' \
        "$(xml_escape "${message}")" "$(xml_escape "${message}")"
    else
      # Explicit close tag, not a self-closing testcase: the flaky-tagging awk in
      # copyArtifacts buffers from <testcase until it sees </testcase> and would
      # otherwise buffer this file to EOF and emit nothing after <testsuite>.
      printf '></testcase>\n'
    fi
    echo '</testsuite>'
  } > "${tmp}"
  mv "${tmp}" "${ARTIFACT_DIR}/junit_quay_preflight.xml"
}

echo "Preflight: waiting up to ${PREFLIGHT_DEADLINE_SECONDS}s for ${PREFLIGHT_REQUIRED_SAMPLES} consecutive healthy samples from ${DISCOVERY_URL}"
: > "${READINESS_LOG}"
preflight_start="$(date +%s)"
preflight_deadline=$((preflight_start + PREFLIGHT_DEADLINE_SECONDS))
consecutive=0
attempt=0
PROBE_CLASS=""
PROBE_DETAIL=""
last_bad_class=""
last_bad_detail=""
while :; do
  attempt=$((attempt + 1))
  probe_route "${attempt}"
  if [[ "${PROBE_CLASS}" == "ok" ]]; then
    consecutive=$((consecutive + 1))
    echo "  preflight ${consecutive}/${PREFLIGHT_REQUIRED_SAMPLES} (attempt ${attempt}, ${PROBE_DETAIL})"
    if [[ "${consecutive}" -ge "${PREFLIGHT_REQUIRED_SAMPLES}" ]]; then
      break
    fi
  else
    echo "  preflight not ready (attempt ${attempt}, ${PROBE_CLASS}: ${PROBE_DETAIL})"
    last_bad_class="${PROBE_CLASS}"
    last_bad_detail="${PROBE_DETAIL}"
    consecutive=0
  fi
  if [[ "$(date +%s)" -ge "${preflight_deadline}" ]]; then
    break
  fi
  sleep 5
done
preflight_seconds=$(( $(date +%s) - preflight_start ))
if [[ "${consecutive}" -ge "${PREFLIGHT_REQUIRED_SAMPLES}" ]]; then
  write_preflight_junit 0 "${preflight_seconds}" ""
  echo "Preflight passed in ${preflight_seconds}s over ${attempt} attempts; starting tests."
else
  # The last sample can be healthy when the deadline expires mid-streak (a flapping
  # route), so report the flap rather than mislabelling the failure "ok".
  if [[ "${PROBE_CLASS}" == "ok" ]]; then
    fail_class="flapping"
    fail_detail="reached only ${consecutive}/${PREFLIGHT_REQUIRED_SAMPLES} consecutive healthy samples; last unhealthy sample was ${last_bad_class}: ${last_bad_detail}"
  else
    fail_class="${PROBE_CLASS}"
    fail_detail="${PROBE_DETAIL}"
  fi
  PREFLIGHT_MESSAGE="Quay route preflight failed after ${preflight_seconds}s and ${attempt} attempts; failure class ${fail_class}: ${fail_detail}. Per-attempt evidence in readiness.jsonl."
  write_preflight_junit 1 "${preflight_seconds}" "${PREFLIGHT_MESSAGE}"
  echo "ERROR: ${PREFLIGHT_MESSAGE}" >&2
  exit 1
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

startJaegerPortForward

echo "Running Playwright e2e install tests from ${PLAYWRIGHT_WORKDIR} (ref ${PLAYWRIGHT_GIT_REF}, workers ${PLAYWRIGHT_WORKERS})..."
pushd "${PLAYWRIGHT_WORKDIR}"
npx playwright test \
  "${GREP_INVERT_ARGS[@]}" \
  --workers "${PLAYWRIGHT_WORKERS}" \
  --reporter=list,junit,html,json \
  2>&1 | tee "${ARTIFACT_DIR}/playwright-output.log"
popd
