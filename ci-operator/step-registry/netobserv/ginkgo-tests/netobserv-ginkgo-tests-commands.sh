#!/bin/bash

if [[ -f "${SHARED_DIR}/kubeadmin-password" ]]; then
  QE_KUBEADMIN_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
  export QE_KUBEADMIN_PASSWORD
  echo "QE_KUBEADMIN_PASSWORD set from cluster credentials"
fi

set -exuo pipefail

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    # Disable xtrace: proxy-conf.sh may export HTTP_PROXY with embedded credentials.
    set +x
    source "${SHARED_DIR}/proxy-conf.sh"
    set -x
fi

if [ -f "${SHARED_DIR}/runtime_env" ]; then
    source "${SHARED_DIR}/runtime_env"
fi

binhome=$(mktemp -d)
if ! which kubectl; then
  ln -s "$(which oc)" "${binhome}/kubectl"
fi

export PATH="${binhome}:${PATH}"

echo "====> Starting netobserv ginkgo e2e tests"
echo "====> TEST_RUN_MODE: ${TEST_RUN_MODE}"

# ---------------------------------------------------------------------------
# Spyglass HTML report: custom-link-ginkgo.html is picked up by Deck's html
# lens (see core-services/prow/02_config/_config.yaml required_files pattern
# .*/custom-link-.*\.html). This step is shared by every netobserv backend
# component (netobserv-operator, flowlogs-pipeline, netobserv-ebpf-agent), so
# each component's job gets its own report generated from that job's ARTIFACT_DIR.
#
# The function is defined here (before any early exit) and registered on the
# EXIT trap below so the report is always emitted -- including the premerge
# "no test files changed" skip path and any set -e failure.
# ---------------------------------------------------------------------------
write_ginkgo_spyglass_report() {
  local exit_code="${1:-0}"
  local step_name="netobserv-ginkgo-tests"
  local job_safe="${JOB_NAME_SAFE:-${JOB_NAME:-unknown}}"
  local gcs_job_path=""
  # ci-operator uploads to the private test-platform-results bucket, but that bucket is
  # not readable by unauthenticated browsers; the censored public mirror
  # test-platform-results-public is what humans reach from Spyglass. Override via
  # GCS_PUBLIC_BUCKET if the mirror name changes again.
  local gcs_bucket="${GCS_PUBLIC_BUCKET:-test-platform-results-public}"
  local gcsweb_base="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/${gcs_bucket}"
  local artifacts_base=""
  local step_base=""
  local report=""
  local status_label="PASSED"
  local status_color="#81c784"
  local junit_count=0
  local report_count=0
  local write_rc=0
  local reports_tmp="" failures_tmp=""
  local enc="" href="" label=""

  # HTML-escape a string for safe use in text nodes or attribute values.
  # Use sed: bash ${var//\"/&quot;} treats & as the matched text.
  html_escape() {
    printf '%s' "${1-}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
  }

  # Percent-encode one path segment (keeps unreserved RFC 3986 chars).
  urlencode_component() {
    local LC_ALL=C
    local s="${1-}" i c out=""
    for (( i = 0; i < ${#s}; i++ )); do
      c="${s:i:1}"
      case "${c}" in
        [a-zA-Z0-9.~_-]) out+="${c}" ;;
        *) printf -v out '%s%%%02X' "${out}" "'${c}" ;;
      esac
    done
    printf '%s' "${out}"
  }

  # Percent-encode each path component of a relative artifact path; preserve '/'.
  urlencode_path() {
    local path="${1-}" result="" part first=1
    while [[ "${path}" == *"/"* ]]; do
      part="${path%%/*}"
      path="${path#*/}"
      if [[ "${first}" -eq 1 ]]; then
        first=0
      else
        result+="/"
      fi
      result+="$(urlencode_component "${part}")"
    done
    if [[ "${first}" -eq 1 ]]; then
      result="$(urlencode_component "${path}")"
    else
      result+="/$(urlencode_component "${path}")"
    fi
    printf '%s' "${result}"
  }

  if [[ -z "${ARTIFACT_DIR:-}" ]]; then
    echo "====> ARTIFACT_DIR unset; skipping ginkgo Spyglass report"
    return 0
  fi

  report="${ARTIFACT_DIR}/custom-link-ginkgo.html"

  if [[ "${JOB_TYPE:-}" == "presubmit" && -n "${PULL_NUMBER:-}" ]]; then
    gcs_job_path="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
  else
    gcs_job_path="logs/${JOB_NAME}/${BUILD_ID}"
  fi
  # ci-operator uploads ARTIFACT_DIR under .../<test>/<step>/artifacts/
  artifacts_base="${gcsweb_base}/${gcs_job_path}/artifacts/${job_safe}/${step_name}/artifacts"
  step_base="${gcsweb_base}/${gcs_job_path}/artifacts/${job_safe}/${step_name}"

  if [[ "${exit_code}" -ne 0 ]]; then
    status_label="FAILED (exit ${exit_code})"
    status_color="#ef5350"
  fi

  # Collect relative paths (portable; avoid mapfile for older bash)
  reports_tmp="$(mktemp)"
  failures_tmp="$(mktemp)"

  if [[ -d "${ARTIFACT_DIR}" ]]; then
    find "${ARTIFACT_DIR}" -type f \( -iname '*.xml' -o -iname '*.json' -o -iname '*.log' -o -iname '*.txt' \) 2>/dev/null \
      | sed "s|^${ARTIFACT_DIR}/||" | sort > "${reports_tmp}" || true
    report_count="$(wc -l < "${reports_tmp}" | tr -d ' ')"
    junit_count="$(find "${ARTIFACT_DIR}" -type f -name '*.xml' 2>/dev/null | wc -l | tr -d ' ')"
  fi

  # Best-effort JUnit failure extraction (no python dependency)
  if [[ -d "${ARTIFACT_DIR}" ]]; then
    # shellcheck disable=SC2086
    find "${ARTIFACT_DIR}" -type f -name '*.xml' -exec grep -h 'failure message="' {} + 2>/dev/null \
      | sed -e 's/.*failure message="//' -e 's/".*//' \
            -e "s/\&apos;/'/g" -e 's/\&quot;/"/g' -e 's/\&lt;/</g' -e 's/\&gt;/>/g' -e 's/\&amp;/\&/g' \
      | grep -E '.' | sort -u | head -40 > "${failures_tmp}" || true
  fi

  {
    cat <<EOF
<html>
<head>
  <title>NetObserv ginkgo debug</title>
  <meta name="description" content="Links to ginkgo backend e2e logs, JUnit failures, and report artifacts for netobserv-ginkgo-tests.">
  <style>
    body {
      background-color: #303030;
      color: #eee;
      font-family: "Roboto", "Helvetica", "Arial", sans-serif;
      padding: 16px;
      margin: 0;
      font-size: 14px;
    }
    h1 { font-size: 18px; margin: 0 0 8px 0; }
    h2 { font-size: 15px; margin: 18px 0 8px 0; color: #90caf9; }
    .status { color: ${status_color}; font-weight: 700; margin-bottom: 12px; }
    a {
      color: #4fc3f7;
      text-decoration: none;
    }
    a:hover { text-decoration: underline; }
    .btn {
      display: inline-block;
      padding: 6px 14px;
      margin: 4px 8px 4px 0;
      border: 2px solid #4E9AF1;
      border-radius: 1em;
      color: #fff !important;
      background-color: #4E9AF1;
      text-decoration: none !important;
    }
    .btn:hover { border-color: #fff; }
    ul { margin: 6px 0 0 18px; padding: 0; }
    li { margin: 4px 0; word-break: break-all; }
    pre {
      background: #212121;
      border: 1px solid #555;
      padding: 10px;
      overflow-x: auto;
      white-space: pre-wrap;
      max-height: 320px;
    }
    .muted { color: #aaa; font-size: 12px; }
    .empty { color: #999; font-style: italic; }
  </style>
</head>
<body>
  <h1>NetObserv ginkgo debug</h1>
  <div class="status">${status_label}</div>
  <p class="muted">Step <code>${step_name}</code> · job <code>$(html_escape "${JOB_NAME:-unknown}")</code> · build <code>$(html_escape "${BUILD_ID:-unknown}")</code></p>

  <h2>Quick links</h2>
  <a class="btn" href="$(html_escape "${step_base}/build-log.txt")" target="_blank">Step build log</a>
  <a class="btn" href="$(html_escape "${artifacts_base}/junit_netobserv_e2e.xml")" target="_blank">JUnit report (XML)</a>
  <a class="btn" href="$(html_escape "${artifacts_base}/")" target="_blank">Artifacts folder</a>

  <h2>Failure messages (${junit_count} JUnit file(s))</h2>
EOF

    if [[ -s "${failures_tmp}" ]]; then
      echo "  <pre>"
      # Escape HTML special chars for safe embedding
      sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "${failures_tmp}"
      echo "  </pre>"
    else
      if [[ "${exit_code}" -ne 0 ]]; then
        echo '  <p class="empty">No failure messages parsed from JUnit (check the step build log).</p>'
      else
        echo '  <p class="empty">No failures recorded.</p>'
      fi
    fi

    echo "  <h2>Report artifacts (${report_count})</h2>"
    if [[ "${report_count}" -gt 0 ]]; then
      echo "  <ul>"
      while IFS= read -r rel; do
        [[ -z "${rel}" ]] && continue
        enc="$(urlencode_path "${rel}")"
        href="$(html_escape "${artifacts_base}/${enc}")"
        label="$(html_escape "${rel}")"
        echo "    <li><a href=\"${href}\" target=\"_blank\">${label}</a></li>"
      done < "${reports_tmp}"
      echo "  </ul>"
    else
      echo '  <p class="empty">No report artifacts uploaded.</p>'
    fi

    cat <<EOF
  <p class="muted">Tip: full ginkgo console output (with <code>--v</code>) is in the step build log linked above.</p>
</body>
</html>
EOF
  } > "${report}" || write_rc=$?

  if [[ "${write_rc}" -eq 0 ]]; then
    echo "====> Wrote ginkgo Spyglass report: ${report}"
    echo "====> Spyglass / GCSWEB artifacts base: ${artifacts_base}/"
  fi
  rm -f "${reports_tmp}" "${failures_tmp}"
  return "${write_rc}"
}

# Emit the report on any exit path (early skip, failure, or success).
# Capture the incoming shell status first: adopt it only when no ginkgo failure
# was already recorded, so recorded ginkgo failures win over an earlier/later
# shell failure while the latter is still reflected on a clean ginkgo run.
GINKGO_EXIT=0
trap 'RC=$?; if [[ "${GINKGO_EXIT}" -eq 0 ]]; then GINKGO_EXIT=${RC}; fi; write_ginkgo_spyglass_report "${GINKGO_EXIT}" || echo "====> Warning: failed to write ginkgo Spyglass report"' EXIT

FOCUS_FILE_ARG=""
LABEL_FILTER_ARG=""
SKIP_FILTER_ARG=""

if [[ -n "${GINKGO_FOCUS_FILE}" ]]; then
  FOCUS_FILE_ARG="--focus-file=${GINKGO_FOCUS_FILE}"
  echo "Using explicit focus-file: ${GINKGO_FOCUS_FILE}"
elif [[ "${TEST_RUN_MODE}" == "premerge" && -f "${SHARED_DIR}/changed_files" ]]; then
  CHANGED_TEST_FILES=""
  while IFS= read -r file; do
    if [[ "${file}" =~ ^integration-tests/backend/(.*_test\.go|test_.*\.go)$ ]]; then
      basename=$(basename "${file}")
      if [[ -n "${CHANGED_TEST_FILES}" ]]; then
        CHANGED_TEST_FILES="${CHANGED_TEST_FILES}|${basename}"
      else
        CHANGED_TEST_FILES="${basename}"
      fi
    fi
  done < "${SHARED_DIR}/changed_files"

  if [[ -z "${CHANGED_TEST_FILES}" ]]; then
    echo "No test files changed in pre-merge mode, skipping tests"
    exit 0
  fi
  FOCUS_FILE_ARG="--focus-file=(${CHANGED_TEST_FILES})"
  echo "Running tests from changed files: ${CHANGED_TEST_FILES}"
else
  echo "Running all tests"
fi

if [[ -n "${GINKGO_LABEL_FILTER}" ]]; then
  LABEL_FILTER_ARG="--label-filter=${GINKGO_LABEL_FILTER}"
  echo "Using label filter: ${GINKGO_LABEL_FILTER}"
fi

if [[ -n "${GINKGO_FOCUS_FILTER}" ]]; then
  FOCUS_FILTER_ARG="--focus=${GINKGO_FOCUS_FILTER}"
  echo "Using focus filter: ${GINKGO_FOCUS_FILTER}"
fi

# skip tests with ginkgo args if they're going to be skipped in generic all tests jobs
if [[ "${JOB_NAME_SAFE}" != *"ipv6"* && "${JOB_NAME_SAFE}" != *"virt"* && "${JOB_NAME_SAFE}" != *"vsphere"* ]]; then
  SPECIALIZED_SKIP="82637|77894|with VMs|53844|83022"
  if [[ -n "${GINKGO_SKIP_FILTER}" ]]; then
    GINKGO_SKIP_FILTER="${GINKGO_SKIP_FILTER}|${SPECIALIZED_SKIP}"
  else
    GINKGO_SKIP_FILTER="${SPECIALIZED_SKIP}"
  fi
  echo "All tests job detected, appending specialized test exclusions to skip filter"
fi

if [[ -n "${GINKGO_SKIP_FILTER}" ]]; then
  SKIP_FILTER_ARG="--skip=${GINKGO_SKIP_FILTER}"
  echo "Using skip filter: ${GINKGO_SKIP_FILTER}"
fi

echo "====> Running ginkgo tests"
# JUNIT_REPORT_FILE is used instead of --junit-report so the test binary can write
# a filtered JUnit XML containing only sig-netobserv specs (via ReportAfterSuite hook).
# Using --junit-report would cause ginkgo to overwrite our filtered output with the full
# unfiltered report (all 7000+ upstream specs) after our hook runs.
export JUNIT_REPORT_FILE="${ARTIFACT_DIR}/junit_netobserv_e2e.xml"
ginkgo run \
  --timeout="${GINKGO_TIMEOUT}" \
  --v \
  --keep-going \
  --output-dir="${ARTIFACT_DIR}" \
  ${FOCUS_FILTER_ARG:+"${FOCUS_FILTER_ARG}"} \
  ${FOCUS_FILE_ARG:+"${FOCUS_FILE_ARG}"} \
  ${LABEL_FILTER_ARG:+"${LABEL_FILTER_ARG}"} \
  ${SKIP_FILTER_ARG:+"${SKIP_FILTER_ARG}"} \
  ./e2e-tests.test || GINKGO_EXIT=$?

if [[ "${GINKGO_EXIT}" -ne 0 ]]; then
  echo "ginkgo-tests failed with exit code ${GINKGO_EXIT}" >> "${SHARED_DIR}/netobserv-step-failures"
  echo "====> Tests completed with failures (exit ${GINKGO_EXIT}), continuing to next step"
else
  echo "====> Tests completed successfully"
fi
