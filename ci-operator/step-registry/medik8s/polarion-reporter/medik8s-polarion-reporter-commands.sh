#!/bin/bash
set -eu -o pipefail

if [[ -z "${SHARED_DIR:-}" ]]; then
  echo "ERROR: SHARED_DIR is not set."
  exit 1
fi

echo "Collecting *_testrun.xml files from \$SHARED_DIR..."
shopt -s nullglob
xml_files=("${SHARED_DIR}"/*_testrun.xml)
shopt -u nullglob

if [[ ${#xml_files[@]} -eq 0 ]]; then
  if [[ "${ECO_ENABLE_REPORT:-}" == "true" ]]; then
    echo "ERROR: ECO_ENABLE_REPORT=true but no *_testrun.xml files in \$SHARED_DIR." >&2
    exit 1
  fi
  echo "No *_testrun.xml files found in \$SHARED_DIR."
  exit 0
fi

echo "Found ${#xml_files[@]} file(s): ${xml_files[*]}"

metadata_file=$(mktemp "${TMPDIR:-/tmp}"/datarouter-meta.XXXXXX)
cleanup() { rm -f "${metadata_file}"; }
trap cleanup EXIT

jq -n \
  --arg project "${POLARION_PROJECT_ID:-OSE}" \
  --arg testrun "${POLARION_TESTRUN_ID:-}" \
  '{
    "targets": {
      "polarion": {
        "config": {
          "project": $project,
          "disable_xunit_importer": true
        },
        "processing": {
          "testsuite_properties": (
            {
              "polarion-testrun-status-id": "inprogress",
              "polarion-include-skipped": "false"
            }
            + if $testrun != "" then
                {"polarion-testrun-id": $testrun}
              else {} end
          )
        }
      }
    }
  }' > "${metadata_file}"

echo "Metadata: $(cat "${metadata_file}")"
echo "Uploading to DataRouter (project=${POLARION_PROJECT_ID:-OSE} testrun=${POLARION_TESTRUN_ID:-<new>})..."

# droute requires --password on the CLI (no env-var support).
[[ $- == *x* ]] && _xtrace_was_on=true || _xtrace_was_on=false
set +x
rc=0
droute send \
  --wait=8 \
  --url "${DATAROUTER_URL}" \
  --username "$(cat /var/run/datarouter/username)" \
  --password "$(cat /var/run/datarouter/password)" \
  --metadata "${metadata_file}" \
  --results "${SHARED_DIR}/*_testrun.xml" || rc=$?
$_xtrace_was_on && set -x

if [[ $rc -ne 0 ]]; then
  echo "ERROR: droute send failed (exit $rc). Check DataRouter credentials and endpoint (${DATAROUTER_URL})." >&2
  exit 1
fi

echo "DataRouter upload complete."
