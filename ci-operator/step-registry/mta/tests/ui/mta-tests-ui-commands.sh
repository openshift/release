#!/bin/bash
# Run MTA Cypress UI tests. Requires SHARED_DIR (with console.url) and ARTIFACT_DIR from the step framework.
set -euxo pipefail
shopt -s inherit_errexit

# Env used by CleanupCollect/yq; defaults match step ref so they are always set (for trap and subprocesses).
export MAP_TESTS="${MAP_TESTS:-false}"
export MAP_TESTS_SUITE_NAME="${MAP_TESTS_SUITE_NAME:-MTA-lp-interop}"

function InstallYq() {
    : "Installing yq for MAP_TESTS (suite name mapping)..."
    mkdir -p /tmp/bin
    export PATH="${PATH}:/tmp/bin"
    typeset arch=""
    arch="$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')"
    curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${arch}" \
        -o /tmp/bin/yq && chmod +x /tmp/bin/yq
    /tmp/bin/yq --version || export MAP_TESTS=false
}

# Merge multiple jUnit XML files into one (avoids naming conflict with other Steps). Optionally map suite name for CR.
# Archives original XMLs so Prow does not see duplicated results. Only ARTIFACT_DIR root (maxdepth 1).
function CleanupCollect() {
    typeset mergedFN="${1:-jUnit.xml}"; (($#)) && shift
    typeset resultFile=''
    typeset -a xmlFiles=()

    InstallYq || true

    while IFS= read -r -d '' resultFile; do
        [[ "$(basename "${resultFile}")" == "${mergedFN}" ]] && continue
        grep -qE '<testsuites?\b' "${resultFile}" && xmlFiles+=("${resultFile}") || true
    done < <(find "${ARTIFACT_DIR}" -maxdepth 1 -type f -iname "*.xml" -print0)

    ((${#xmlFiles[@]})) || {
        echo "Warning: No JUnit XML file found to process" >&2
        true
        return
    }

    # Prepare one jUnit XML: collect -> map suite name and merge
    yq eval-all -px -ox -I2 '
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

trap 'CleanupCollect junit--mta__tests__ui--mta-tests-ui.xml' EXIT

# Local test: only run CleanupCollect then exit (ARTIFACT_DIR/SHARED_DIR must be set by caller).
if [[ -n "${RUN_LOCAL_TEST:-}" ]]; then
    set +x
    exit 0
fi

# Derive TARGET_URL from the install step's console URL. console.url must be the full console URL.
typeset console_url
console_url="$(cat "${SHARED_DIR}/console.url" 2>/dev/null || true)"
if [[ -z "${console_url}" ]]; then
    echo "Error: SHARED_DIR/console.url is missing or empty" >&2
    exit 1
fi
if [[ "${console_url}" != "https://"* ]]; then
    echo "Error: console.url must be an HTTPS URL (got: ${console_url})" >&2
    exit 1
fi
typeset target_url="https://mta-mta.${console_url#"https://console-openshift-console."}"
if [[ -z "${target_url}" || "${target_url}" == "https://mta-mta." ]]; then
    echo "Error: TARGET_URL could not be derived from console.url (expected pattern https://console-openshift-console.<domain>; got: CONSOLE_URL=${console_url})" >&2
    exit 1
fi
if [[ "${target_url}" != *"."* ]]; then
    echo "Error: TARGET_URL has no domain (got: ${target_url})" >&2
    exit 1
fi

# Set the scope (tag filter, e.g. @interop)
export CYPRESS_INCLUDE_TAGS="${MTA_TESTS_UI_SCOPE:-@interop}"

# Run only tier files for the scope when findTierFiles.mjs exists (image is built from cypress context).
typeset cypress_spec="${CYPRESS_SPEC:-}"
if [ -f "scripts/findTierFiles.mjs" ]; then
    cypress_spec="$(node scripts/findTierFiles.mjs "${MTA_TESTS_UI_SCOPE:-@interop}" || true)"
    [ -n "${cypress_spec}" ] && export CYPRESS_SPEC="${cypress_spec}"
fi
export CYPRESS_SPEC="${CYPRESS_SPEC:-e2e/tests/**/*.test.ts}"

# Reduce OOM risk: cap Node heap at 4Gi so Chromium has room; numTestsKeptInMemory=0 below keeps test data minimal.
export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=4096"

# Use test repo's .env.example so dotenvx has a .env; CYPRESS_BASE_URL export overrides.
if [ -f .env.example ]; then
    cp .env.example .env
fi

export TARGET_URL="${target_url}"
export CYPRESS_BASE_URL="${target_url}"

# Execute Cypress via dotenvx. baseUrl comes from CYPRESS_BASE_URL (exported above). || true so we still archive on test failure.
npx dotenvx run -- npx cypress run \
    --config "video=false,numTestsKeptInMemory=0" \
    --spec "${CYPRESS_SPEC}" || true

# Merge per-spec JUnit XML into one file (package.json: mergereports → jrm ./run/report/junitreport.xml ./run/report/junit/*.xml).
npm run mergereports

# jrm output path is relative to cwd (image WORKDIR e.g. /tmp/tackle-ui-tests).
junit_report="${PWD}/run/report/junitreport.xml"
if [[ -f "${junit_report}" ]]; then
    cp -- "${junit_report}" "${ARTIFACT_DIR}/junit_tackle_ui_results.xml"
else
    echo "Error: JUnit report not found at ${junit_report} (PWD=${PWD}). Run 'npm run mergereports' first." >&2
    ls -la "${PWD}/run/report/" 2>/dev/null || true
    exit 1
fi

# Copy screenshots (mochawesome/cypress write to run/screenshots on failure).
mkdir -p "${ARTIFACT_DIR}/screenshots"
for screenshots_src in "/tmp/tackle-ui-tests/run/screenshots" "run/screenshots"; do
    if [ -d "${screenshots_src}" ]; then
        cp -r "${screenshots_src}/." "${ARTIFACT_DIR}/screenshots/"
        break
    fi
done

# Produce one merged JUnit XML for Data Router (runs here and on EXIT via trap).
CleanupCollect junit--mta__tests__ui--mta-tests-ui.xml

true
