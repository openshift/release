#!/usr/bin/env bash

set -euo pipefail

if [[ "${SKIP_FRONTEND_TESTS:-false}" == "true" ]]; then
  echo "====> SKIP_FRONTEND_TESTS=true, skipping frontend tests"
  exit 0
fi

# setup proxy
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

if [ -f "${SHARED_DIR}/runtime_env" ]; then
    source "${SHARED_DIR}/runtime_env"
fi

# Validate KUBECONFIG is set
if [ -z "${KUBECONFIG:-}" ]; then
    echo "ERROR: KUBECONFIG environment variable must be set"
    exit 1
fi

sleep 600
# Get console URL from the cluster
echo "Fetching console URL from cluster..."
CONSOLE_URL=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}' || echo "")
if [ -z "${CONSOLE_URL}" ]; then
    echo "ERROR: Failed to get console URL from cluster"
    exit 1
fi
export CYPRESS_BASE_URL="https://${CONSOLE_URL}"
echo "Console URL: ${CYPRESS_BASE_URL}"

# Retrieve kubeadmin password from shared dir
KUBEADMIN_PASSWORD_FILE="${SHARED_DIR}/kubeadmin-password"
if [ ! -f "${KUBEADMIN_PASSWORD_FILE}" ]; then
    echo "ERROR: kubeadmin password file not found at ${KUBEADMIN_PASSWORD_FILE}"
    exit 1
fi

# Disable tracing to avoid leaking credentials
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
KUBEADMIN_PASSWORD=$(cat "${KUBEADMIN_PASSWORD_FILE}")
export CYPRESS_LOGIN_USERS="kubeadmin:${KUBEADMIN_PASSWORD}"
$WAS_TRACING && set -x

export CYPRESS_LOGIN_IDP="${CYPRESS_LOGIN_IDP:-kube:admin}"
export IS_OPENSHIFT=true
export CYPRESS_GREP_TAGS="${CYPRESS_GREP_TAGS:-@Network_Observability}"
export CYPRESS_KUBECONFIG_PATH="${KUBECONFIG}"


echo "Login IDP: ${CYPRESS_LOGIN_IDP}"
echo "Test filter: ${CYPRESS_GREP_TAGS}"

FRONTEND_EXIT=0
/opt/app-root/scripts/run-e2e-tests.sh || FRONTEND_EXIT=$?

# ---------------------------------------------------------------------------
# Spyglass HTML report: custom-link-cypress.html is picked up by Deck's html
# lens (see core-services/prow/02_config/_config.yaml required_files).
# ---------------------------------------------------------------------------
write_cypress_spyglass_report() {
  local exit_code="${1:-0}"
  local step_name="netobserv-frontend-tests"
  local job_safe="${JOB_NAME_SAFE:-${JOB_NAME:-unknown}}"
  local gcs_job_path=""
  local gcsweb_base="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results"
  local artifacts_base=""
  local step_base=""
  local report=""
  local status_label="PASSED"
  local status_color="#81c784"
  local screenshot_count=0
  local video_count=0
  local junit_count=0
  local write_rc=0
  local screenshots_tmp="" videos_tmp="" failures_tmp=""
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
    echo "====> ARTIFACT_DIR unset; skipping Cypress Spyglass report"
    return 0
  fi

  report="${ARTIFACT_DIR}/custom-link-cypress.html"

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
  screenshots_tmp="$(mktemp)"
  videos_tmp="$(mktemp)"
  failures_tmp="$(mktemp)"

  if [[ -d "${ARTIFACT_DIR}" ]]; then
    find "${ARTIFACT_DIR}" -type f \( -iname '*.png' -o -iname '*.jpg' -o -iname '*.jpeg' \) 2>/dev/null \
      | sed "s|^${ARTIFACT_DIR}/||" | sort > "${screenshots_tmp}" || true
    find "${ARTIFACT_DIR}" -type f -iname '*.mp4' 2>/dev/null \
      | sed "s|^${ARTIFACT_DIR}/||" | sort > "${videos_tmp}" || true
    screenshot_count="$(wc -l < "${screenshots_tmp}" | tr -d ' ')"
    video_count="$(wc -l < "${videos_tmp}" | tr -d ' ')"
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
  <title>NetObserv Cypress debug</title>
  <meta name="description" content="Links to Cypress logs, JUnit failures, screenshots, and videos for netobserv-frontend-tests.">
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
  <h1>NetObserv Cypress debug</h1>
  <div class="status">${status_label}</div>
  <p class="muted">Step <code>${step_name}</code> · job <code>$(html_escape "${JOB_NAME:-unknown}")</code> · build <code>$(html_escape "${BUILD_ID:-unknown}")</code></p>

  <h2>Quick links</h2>
  <a class="btn" href="$(html_escape "${artifacts_base}/cypress-console.log")" target="_blank">Cypress console log</a>
  <a class="btn" href="$(html_escape "${step_base}/build-log.txt")" target="_blank">Step build log</a>
  <a class="btn" href="$(html_escape "${artifacts_base}/")" target="_blank">Artifacts folder</a>
  <a class="btn" href="$(html_escape "${artifacts_base}/junit/")" target="_blank">JUnit folder</a>
  <a class="btn" href="$(html_escape "${artifacts_base}/cypress/screenshots/")" target="_blank">Screenshots folder</a>
  <a class="btn" href="$(html_escape "${artifacts_base}/cypress/videos/")" target="_blank">Videos folder</a>

  <h2>Failure messages (${junit_count} JUnit file(s))</h2>
EOF

    if [[ -s "${failures_tmp}" ]]; then
      echo "  <pre>"
      # Escape HTML special chars for safe embedding
      sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "${failures_tmp}"
      echo "  </pre>"
    else
      if [[ "${exit_code}" -ne 0 ]]; then
        echo '  <p class="empty">No failure messages parsed from JUnit (check Cypress console / build log).</p>'
      else
        echo '  <p class="empty">No failures recorded.</p>'
      fi
    fi

    echo "  <h2>Cypress console log (tail)</h2>"
    if [[ -f "${ARTIFACT_DIR}/cypress-console.log" ]]; then
      echo "  <pre>"
      tail -n 80 "${ARTIFACT_DIR}/cypress-console.log" \
        | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
      echo "  </pre>"
    else
      echo '  <p class="empty">cypress-console.log not found in artifacts.</p>'
    fi

    echo "  <h2>Screenshots (${screenshot_count})</h2>"
    if [[ "${screenshot_count}" -gt 0 ]]; then
      echo "  <ul>"
      while IFS= read -r rel; do
        [[ -z "${rel}" ]] && continue
        enc="$(urlencode_path "${rel}")"
        href="$(html_escape "${artifacts_base}/${enc}")"
        label="$(html_escape "${rel}")"
        echo "    <li><a href=\"${href}\" target=\"_blank\">${label}</a></li>"
      done < "${screenshots_tmp}"
      echo "  </ul>"
    else
      echo '  <p class="empty">No screenshots uploaded.</p>'
    fi

    echo "  <h2>Videos (${video_count})</h2>"
    if [[ "${video_count}" -gt 0 ]]; then
      echo "  <ul>"
      while IFS= read -r rel; do
        [[ -z "${rel}" ]] && continue
        enc="$(urlencode_path "${rel}")"
        href="$(html_escape "${artifacts_base}/${enc}")"
        label="$(html_escape "${rel}")"
        echo "    <li><a href=\"${href}\" target=\"_blank\">${label}</a></li>"
      done < "${videos_tmp}"
      echo "  </ul>"
    else
      echo '  <p class="empty">No videos uploaded.</p>'
    fi

    cat <<EOF
  <p class="muted">Tip: open screenshots/videos in a new tab from the links above. Spyglass itself does not render media inline.</p>
</body>
</html>
EOF
  } > "${report}" || write_rc=$?

  if [[ "${write_rc}" -eq 0 ]]; then
    echo "====> Wrote Cypress Spyglass report: ${report}"
    echo "====> Spyglass / GCSWEB artifacts base: ${artifacts_base}/"
  fi
  rm -f "${screenshots_tmp}" "${videos_tmp}" "${failures_tmp}"
  return "${write_rc}"
}

write_cypress_spyglass_report "${FRONTEND_EXIT}" || echo "====> Warning: failed to write Cypress Spyglass report"

if [[ "${FRONTEND_EXIT}" -ne 0 ]]; then
  echo "frontend-tests failed with exit code ${FRONTEND_EXIT}" >> "${SHARED_DIR}/netobserv-step-failures"
  echo "====> Frontend tests completed with failures (exit ${FRONTEND_EXIT}), continuing to next step"
fi
