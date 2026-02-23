#!/bin/bash

# Enable strict mode options including xtrace (-x) and inherit_errexit
set -euxo pipefail; shopt -s inherit_errexit

# Env used by CleanupCollect/yq; defaults match step ref so they are always set (for trap and subprocesses).
export MAP_TESTS="${MAP_TESTS:-false}"
export MAP_TESTS_SUITE_NAME="${MAP_TESTS_SUITE_NAME:-ACS-lp-interop}"

function InstallYq() {
    : "Installing yq if not available..."

    # Install yq manually if not found in image
    mkdir -p /tmp/bin
    export PATH="${PATH}:/tmp/bin"
    typeset arch=""
    arch="$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')"
    curl -L "https://github.com/mikefarah/yq/releases/download/v4.52.4/yq_linux_${arch}" \
        -o /tmp/bin/yq && chmod +x /tmp/bin/yq
    /tmp/bin/yq --version || export MAP_TESTS=false
}

# Merge multiple jUnit XML files into one (avoids naming conflict with other Steps). Optionally map suite name for CR.
# Archives original XMLs so Prow does not see duplicated results.
function CleanupCollect() {
    typeset mergedFN="${1:-jUnit.xml}"; (($#)) && shift
    typeset resultFile=''
    typeset -a xmlFiles=()

    InstallYq || true

    while IFS= read -r -d '' resultFile; do
        grep -qE '<testsuites?\b' "${resultFile}" && xmlFiles+=("${resultFile}") || true
    done < <(find "${ARTIFACT_DIR}" -type f -iname "*.xml" ! -name "${mergedFN}" -print0)

    ((${#xmlFiles[@]})) || {
        : 'Warning: No JUnit XML file found to process'
        true
        return
    }

    # Prepare one jUnit XML: collect -> map suite name and merge
    yq eval-all --input-format xml --output-format xml -I2 '
        {
            "+p_xml": "version=\"1.0\" encoding=\"UTF-8\"",
            "testsuites": {"testsuite": [
                .[] |
                (.testsuite // .) |
                ([] + .)[] |
                select(kind == "map") | (
                    select(env(MAP_TESTS) == "true") |
                    ."+@name" = env(MAP_TESTS_SUITE_NAME)
                )//. |
                ([] + (.testcase // [])) as $tc |
                ."+@tests" = ($tc | length | tostring) |
                ."+@failures" = ([$tc[] | select(.failure)] | length | tostring) |
                ."+@errors" = ([$tc[] | select(.error)] | length | tostring)
            ]}
        }
    ' "${xmlFiles[@]}" 1> "${ARTIFACT_DIR}/${mergedFN}"

    # Archive the original jUnit XMLs so Prow does not see duplicated results.
    tar zcf "${ARTIFACT_DIR}/jUnit-original.tgz" -C "${ARTIFACT_DIR}/" "${xmlFiles[@]#${ARTIFACT_DIR}/}"
    rm -f "${xmlFiles[@]}"

    cp "${ARTIFACT_DIR}/${mergedFN}" "${SHARED_DIR}/"
    true
}

trap 'CleanupCollect junit--stackrox__compliance-e2e__stackrox-compliance-e2e.xml' EXIT

# Determine job name from test suite or job name safe
typeset job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"

# Logic for interop testing
if [ ! -f ".openshift-ci/dispatch.sh" ]; then
    if [ ! -d "stackrox" ]; then
        git clone https://github.com/stackrox/stackrox.git
    fi
    cd stackrox
fi

# Execute dispatch script
.openshift-ci/dispatch.sh "${job}"

true
