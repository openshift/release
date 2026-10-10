#!/bin/bash
# Final step of the operator-upgrade test. Two jobs:
#   1. Merge the per-phase Playwright blob reports (seed + verify, and any other
#      phase that exported one) into a single combined Playwright HTML report.
#   2. Gate the job: exit non-zero if any best-effort Playwright phase recorded a
#      test failure, so the job turns RED even though each phase exited 0 (which is
#      what let every phase run and publish its own report).
#
# Intentionally NOT `set -e`: a hiccup while merging reports must never stop the
# gate from running. No tracing (set -x) and no secret handling here.
set -uo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-operator-upgrade-report"
mkdir -p "${ARTIFACT_DIR}"

SHARED="${SHARED_DIR:-/tmp}"

# The phases write FLAT, phase-unique files to SHARED_DIR (ci-operator does not
# persist SHARED_DIR subdirectories between steps):
#   blob reports -> quay-upgrade-blob-<phase>.zip
#   result rc    -> quay-upgrade-result-<phase>.rc

# ---- 1. Combined Playwright HTML report (best-effort) --------------------------
if compgen -G "${SHARED}/quay-upgrade-blob-*.zip" >/dev/null 2>&1; then
  # merge-reports consumes a DIRECTORY of blob zips, so gather the flat shared
  # files into a scratch dir first.
  BLOB_DIR="$(mktemp -d)"
  cp "${SHARED}"/quay-upgrade-blob-*.zip "${BLOB_DIR}/" || true
  echo "Merging Playwright blob reports into one combined report:"
  ls -1 "${BLOB_DIR}"
  # merge-reports needs an @playwright/test install; the quay-playwright-runner
  # image bakes the suite, so run from its project dir.
  app_dir=""
  for d in /app/web /app "${PLAYWRIGHT_WORKDIR:-}" /tmp/quay-playwright-src/web; do
    if [[ -n "${d}" && ( -f "${d}/playwright.config.ts" || -f "${d}/package.json" ) ]]; then
      app_dir="${d}"
      break
    fi
  done
  (
    [[ -n "${app_dir}" ]] && cd "${app_dir}"
    # Set both env names so the HTML output dir resolves across Playwright versions.
    PLAYWRIGHT_HTML_OUTPUT_DIR="${ARTIFACT_DIR}/combined-playwright-report" \
    PLAYWRIGHT_HTML_REPORT="${ARTIFACT_DIR}/combined-playwright-report" \
      npx playwright merge-reports --reporter html "${BLOB_DIR}"
  ) && echo "Combined report written to ${ARTIFACT_DIR}/combined-playwright-report" \
    || echo "WARNING: merge-reports failed; the per-phase reports are still published."

  # Surface the combined report as a clickable Spyglass link, mirroring the
  # per-phase links the runner writes.
  if [[ -f "${ARTIFACT_DIR}/combined-playwright-report/index.html" ]]; then
    gcs_base="https://gcs.ci.openshift.org/gcs/test-platform-results-public"
    if [[ "${JOB_TYPE:-}" == "presubmit" && -n "${PULL_NUMBER:-}" ]]; then
      gcs_path="pr-logs/pull/${REPO_OWNER:-}_${REPO_NAME:-}/${PULL_NUMBER:-}/${JOB_NAME:-}/${BUILD_ID:-}"
    else
      gcs_path="logs/${JOB_NAME:-}/${BUILD_ID:-}"
    fi
    report_url="${gcs_base}/${gcs_path}/artifacts/${JOB_NAME_SAFE:-}/quay-operator-upgrade-report/artifacts/quay-operator-upgrade-report/combined-playwright-report/index.html"
    cat > "${ARTIFACT_DIR}/custom-link-combined-playwright-report.html" <<EOF || true
<html>
<head>
<title>Combined upgrade Playwright report</title>
<style>
a { display:inline-block; padding:5px 20px; margin:10px; border:2px solid #4E9AF1; border-radius:1em; text-decoration:none; color:#FFFFFF !important; background-color:#4E9AF1; }
</style>
</head>
<body>
<a target="_blank" href="${report_url}">Combined seed + verify Playwright report</a>
</body>
</html>
EOF
  fi
else
  echo "No Playwright blob reports found in ${SHARED}; skipping the combined report."
fi

# ---- 2. Gate: fail the job if any best-effort phase had test failures ----------
rc=0
shopt -s nullglob
markers=("${SHARED}"/quay-upgrade-result-*.rc)
if (( ${#markers[@]} == 0 )); then
  echo "WARNING: no phase result markers in ${SHARED}; nothing to gate on."
else
  echo "Playwright upgrade phase results:"
  for f in "${markers[@]}"; do
    phase="$(basename "${f}" .rc)"
    phase="${phase#quay-upgrade-result-}"
    v="$(cat "${f}" 2>/dev/null || echo 1)"
    if [[ "${v}" == "0" ]]; then
      echo "  phase ${phase}: PASS"
    else
      echo "  phase ${phase}: FAIL (playwright exit ${v})"
      rc=1
    fi
  done
fi

if (( rc != 0 )); then
  echo "ERROR: one or more Playwright upgrade phases had test failures; failing the job." >&2
else
  echo "All Playwright upgrade phases passed."
fi
exit "${rc}"
