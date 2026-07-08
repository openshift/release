#!/bin/bash
set -eu -o pipefail

if [[ -z "${SHARED_DIR:-}" ]]; then
  echo "ERROR: SHARED_DIR is not set — cannot locate test result XML files."
  exit 1
fi

echo "Collecting *_testrun.xml files from \$SHARED_DIR..."
shopt -s nullglob
xml_files=("${SHARED_DIR}"/*_testrun.xml)
shopt -u nullglob

if [[ ${#xml_files[@]} -eq 0 ]]; then
  echo "No *_testrun.xml files found in \$SHARED_DIR — skipping DataRouter upload."
  exit 0
fi

echo "Found ${#xml_files[@]} file(s): ${xml_files[*]}"

metadata_file=$(mktemp "${TMPDIR:-/tmp}"/datarouter-meta.XXXXXX.json)
cleanup() { rm -f "${metadata_file}"; }
trap cleanup EXIT

if [[ -n "${POLARION_TESTRUN_ID:-}" ]]; then
  jq -n \
    --arg project "${POLARION_PROJECT_ID:-}" \
    --arg testrun "${POLARION_TESTRUN_ID:-}" \
    '{"polarion-project-id": $project, "polarion-testrun-id": $testrun}' \
    > "${metadata_file}"
else
  jq -n \
    --arg project "${POLARION_PROJECT_ID:-}" \
    '{"polarion-project-id": $project}' \
    > "${metadata_file}"
fi

echo "Uploading to DataRouter (url=${DATAROUTER_URL} project=${POLARION_PROJECT_ID:-} testrun=${POLARION_TESTRUN_ID:-<new>})..."

# droute requires --password as a CLI flag; no env-var alternative exists in this binary version.
# The CI pod is single-tenant and isolated, limiting the process-argv exposure window.
if ! droute send \
  --wait=8 \
  --url "${DATAROUTER_URL}" \
  --username "$(cat /var/run/datarouter/username)" \
  --password "$(cat /var/run/datarouter/password)" \
  --metadata "${metadata_file}" \
  --results "${SHARED_DIR}/*_testrun.xml"; then
  echo "ERROR: droute send failed (exit $?) — check DataRouter credentials and endpoint." >&2
  exit 1
fi

echo "DataRouter upload complete."
