#!/bin/bash

SNYK_TOKEN="$(cat $SNYK_TOKEN_PATH)"
export SNYK_TOKEN

# install snyk
SNYK_DIR=/tmp/snyk
mkdir -p ${SNYK_DIR}

curl https://static.snyk.io/cli/latest/snyk-linux -o $SNYK_DIR/snyk
chmod +x ${SNYK_DIR}/snyk

echo snyk installed to ${SNYK_DIR}
${SNYK_DIR}/snyk --version

snyk_deps() {
    echo Starting snyk dependencies scan
    PARAMS=(--project-name="$PROJECT_NAME" --org="$ORG_NAME")
    if [ "$ALL_PROJECTS" = "true" ]; then
        PARAMS+=(--all-projects)
    fi
    ${SNYK_DIR}/snyk test "${PARAMS[@]}"
}

snyk_code() {
    echo Starting snyk code scan
    PARAMS=(--project-name="$PROJECT_NAME" --org="$ORG_NAME"  --sarif-file-output="${ARTIFACT_DIR}/snyk.sarif.json" --report)
    ${SNYK_DIR}/snyk code test "${PARAMS[@]}"
    local rc=$?
    echo Full vulnerabilities report is available at ${ARTIFACT_DIR}/snyk.sarif.json
    return $rc
}

declare -A commands
commands=( ["snyk_deps"]="snyk dependencies scan failed" ["snyk_code"]="snyk code scan failed" )

declare -A results
all_successful=true
for cmd in "${!commands[@]}"; do
    if $cmd; then
        results["$cmd"]=0
    else
        results["$cmd"]=1
        all_successful=false
    fi
done

for cmd in "${!results[@]}"; do
    if [ ${results["$cmd"]} -ne 0 ]; then
        echo "${commands["$cmd"]}"
    fi
done

if [ "$all_successful" = "false" ]; then
    exit 1
fi
