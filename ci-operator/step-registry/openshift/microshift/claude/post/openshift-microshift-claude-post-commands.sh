#!/bin/bash
set -euo pipefail
set -x

copy_report_pages() {
    echo "Copying report HTML files from shared directory to artifacts..."
    for f in "${SHARED_DIR}"/*.html; do
        local base
        base="$(basename "${f}" .html)"
        cp "${f}" "${ARTIFACT_DIR}/1-${base}-summary.html"
    done
}

#
# Main
#
echo "Generating the report pages..."

if [[ -f "${SHARED_DIR}/claude-report-available" ]]; then
    copy_report_pages
else
    echo "No Claude report found. Skipping."
fi
