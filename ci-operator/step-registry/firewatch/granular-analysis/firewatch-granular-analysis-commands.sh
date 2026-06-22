#!/bin/bash

set -o nounset
set -o pipefail

artifact_dir="${ARTIFACT_DIR}"
if [ -n "${FIREWATCH_GRANULAR_ARTIFACT_SUBDIR:-}" ]; then
    artifact_dir="${ARTIFACT_DIR}/${FIREWATCH_GRANULAR_ARTIFACT_SUBDIR}"
fi

output_dir="${SHARED_DIR}"

echo "Running firewatch-granular-analysis..."
echo "  Artifact dir: ${artifact_dir}"
echo "  Output dir: ${output_dir}"

firewatch-granular analyze \
    --artifact-dir "${artifact_dir}" \
    --output-dir "${output_dir}"

exit_code=$?

if [ -f "${output_dir}/firewatch-additional-labels" ]; then
    echo "Labels written:"
    cat "${output_dir}/firewatch-additional-labels"
fi

if [ -f "${output_dir}/firewatch-granular-data.json" ]; then
    echo "Report written to ${output_dir}/firewatch-granular-data.json"
fi

exit ${exit_code}
