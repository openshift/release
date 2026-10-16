#!/bin/bash
# Final step of the operator-upgrade test. Two jobs:
#   1. Link the combined Playwright HTML report that the last phase (functional)
#      merged inside its own pod (all upgrade phases' tests, logs and traces in
#      one report). Its full-suite blob is far larger than the 1MiB Kubernetes
#      Secret backing SHARED_DIR, so the merge cannot happen in this step --
#      the functional phase leaves a pointer file with the merged report's
#      public GCS URL in SHARED_DIR. If that pointer is missing, fall back to
#      merging the small seed/verify blobs that did fit in SHARED_DIR.
#   2. Gate the job: exit non-zero if any best-effort Playwright phase recorded a
#      test failure, or if none recorded a result, so the job turns RED even
#      though each phase exited 0 (which is what let every phase run and publish
#      its own report).
#
# Intentionally NOT `set -e`: a hiccup while merging reports must never stop the
# gate from running. No tracing (set -x) and no secret handling here.
set -uo pipefail

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp/artifacts}/quay-operator-upgrade-report"
mkdir -p "${ARTIFACT_DIR}"

SHARED="${SHARED_DIR:-/tmp}"

# The phases write FLAT, phase-unique files to SHARED_DIR (ci-operator does not
# persist SHARED_DIR subdirectories between steps):
#   combined-report pointer -> quay-upgrade-combined-report.path (tiny: the URL)
#   subset blob reports     -> quay-upgrade-blob-<phase>.zip
#   result rc               -> quay-upgrade-result-<phase>.rc

# Prow's html lens renders artifacts matching custom-link-*.html near the top
# of the Spyglass page and uses <title> as the section name. Emit a rich card
# titled "Quay upgrade test results" (matching the e2e-install layout) so the
# upgrade job has one clear primary row distinct from the per-phase cards.
gcs_job_artifacts_prefix() {
  local gcs_base="https://gcs.ci.openshift.org/gcs/test-platform-results-public"
  local gcs_path
  if [[ "${JOB_TYPE:-}" == "presubmit" && -n "${PULL_NUMBER:-}" ]]; then
    gcs_path="pr-logs/pull/${REPO_OWNER:-}_${REPO_NAME:-}/${PULL_NUMBER:-}/${JOB_NAME:-}/${BUILD_ID:-}"
  else
    gcs_path="logs/${JOB_NAME:-}/${BUILD_ID:-}"
  fi
  echo "${gcs_base}/${gcs_path}/artifacts/${JOB_NAME_SAFE:-}"
}

write_combined_link() {
  local report_url="${1:?}"
  local steps_base
  steps_base="$(gcs_job_artifacts_prefix)"
  # Phase HTML reports live under each playwright step's ARTIFACT_DIR + subdir.
  local seed_url="${steps_base}/quay-operator-upgrade-seed-playwright/artifacts/n-minus-one-seed/index.html"
  local verify_url="${steps_base}/quay-operator-upgrade-verify-playwright/artifacts/n-verify/index.html"
  local functional_url="${steps_base}/quay-operator-upgrade-functional-playwright/artifacts/n-functional/index.html"
  {
    cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Quay upgrade test results</title>
<meta name="description" content="Links for triaging Quay upgrade test results">
<style>
body { margin: 0; font: 14px/1.4 Roboto, "Helvetica Neue", Arial, sans-serif; color: #151515; }
main { padding: 12px 18px 16px; }
ul { display: flex; flex-wrap: wrap; gap: 8px; margin: 0; padding: 0; list-style: none; }
li { flex: 1 1 180px; max-width: 260px; }
a { display: block; height: 100%; box-sizing: border-box; padding: 8px 12px; border: 1px solid #d2d2d2; border-left: 3px solid #0066cc; border-radius: 4px; color: #0066cc; font-weight: 500; text-decoration: none; }
a:hover, a:focus { background: #f0f7ff; border-color: #0066cc; }
a span { display: block; color: #6a6e73; font-size: 12px; font-weight: 400; }
</style>
</head>
<body>
<main>
<ul>
<li><a target="_blank" href="${report_url}">Combined Playwright report<span>All phases: failures, traces and screenshots</span></a></li>
<li><a target="_blank" href="${seed_url}">Seed phase report<span>n-1 @upgrade-seed fixtures</span></a></li>
<li><a target="_blank" href="${verify_url}">Verify phase report<span>n @upgrade-verify persistence</span></a></li>
<li><a target="_blank" href="${functional_url}">Functional phase report<span>n full-suite regression</span></a></li>
<li><a target="_blank" href="${steps_base}/quay-gather/artifacts/">Quay logs<span>Pods, events and container logs</span></a></li>
<li><a target="_blank" href="${steps_base}/gather-must-gather/artifacts/">must-gather<span>Cluster state after the run</span></a></li>
</ul>
</main>
</body>
</html>
EOF
  } > "${ARTIFACT_DIR}/custom-link-quay-upgrade-results.html" || true
}

# ---- 1. Combined Playwright HTML report (best-effort) --------------------------
# The last playwright phase (functional) merges all phases' blob reports inside
# its own pod, because its full-suite blob is far larger than the 1MiB
# Kubernetes Secret backing SHARED_DIR and can never travel through it; it
# leaves a tiny pointer file here with the merged report's public GCS URL (the
# URL resolves once Prow uploads the artifact tree at job end). Link that. If
# the pointer is missing (that phase crashed early, merge-reports failed, ...),
# fall back to merging whatever small subset blobs did make it into SHARED_DIR,
# which is how this step originally built the combined report.
combined_pointer="${SHARED}/quay-upgrade-combined-report.path"
if [[ -s "${combined_pointer}" ]]; then
  report_url="$(cat "${combined_pointer}")"
  echo "Combined upgrade report was merged by the functional phase; linking:"
  echo "  ${report_url}"
  write_combined_link "${report_url}"
elif compgen -G "${SHARED}/quay-upgrade-blob-*.zip" >/dev/null 2>&1; then
  # merge-reports consumes a DIRECTORY of blob zips, so gather the flat shared
  # files into a scratch dir first.
  BLOB_DIR="$(mktemp -d)"
  cp "${SHARED}"/quay-upgrade-blob-*.zip "${BLOB_DIR}/" || true
  echo "Falling back to merging Playwright blob reports found in ${SHARED}:"
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
    if [[ -n "${app_dir}" ]]; then cd "${app_dir}"; fi
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
    write_combined_link "${report_url}"
  fi
else
  echo "No combined-report pointer and no Playwright blob reports in ${SHARED}; skipping the combined report."
fi

# ---- 2. Gate: fail the job if any best-effort phase had test failures ----------
rc=0
shopt -s nullglob
markers=("${SHARED}"/quay-upgrade-result-*.rc)
if (( ${#markers[@]} == 0 )); then
  echo "ERROR: no phase result markers in ${SHARED}; no Playwright phase reported a result." >&2
  rc=1
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
  echo "ERROR: the Playwright upgrade gate failed (see above); failing the job." >&2
else
  echo "All Playwright upgrade phases passed."
fi
exit "${rc}"
