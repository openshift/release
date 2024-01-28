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

# install jq if not installed
if ! [ -x "$(command -v jq)" ]; then
    JQ_CHECKSUM="2f312b9587b1c1eddf3a53f9a0b7d276b9b7b94576c85bda22808ca950569716" # https://github.com/jqlang/jq/tree/master/sig
    curl -Lo ${SNYK_DIR}/jq "https://github.com/jqlang/jq/releases/download/jq-1.7/jq-linux-amd64"

    actual_checksum=$(sha256sum ${SNYK_DIR}/jq | cut -d ' ' -f 1)
    if [ "${actual_checksum}" != "${JQ_CHECKSUM}" ]; then
        echo "Checksum of downloaded JQ didn't match expected checksum"
        exit 1
    fi

    chmod +x ${SNYK_DIR}/jq
    export PATH=${PATH}:${SNYK_DIR}
fi

CLONE_REFS=$(echo $CLONEREFS_OPTIONS | jq -r ".refs | map(select(.base_ref == \"$(git rev-parse --abbrev-ref HEAD)\")) | if length > 1 then del(.[] | select(.repo == \"release\" and .org == \"openshift\")) else . end | .[]")

if [ -z "${PROJECT_NAME}" ]; then
    PROJECT_NAME=$(echo $CLONE_REFS | jq -r "( .org + \"/\" + .repo )")
fi

snyk_deps() {
    if [ "$SNYK_ENABLE_DEPS_SCAN" != "true" ]; then
        echo "Skipping snyk dependencies scan"
        return 0
    fi
    echo Starting snyk dependencies scan
    PARAMS=(--project-name="$PROJECT_NAME" --org="$ORG_NAME")
    if [ "$ALL_PROJECTS" = "true" ]; then
        PARAMS+=(--all-projects)
    fi
    if [ "$SNYK_DEPS_ADDITIONAL_ARGS" ]; then
        read -a PARAMS <<<"$SNYK_DEPS_ADDITIONAL_ARGS"
    fi
    ${SNYK_DIR}/snyk test "${PARAMS[@]}"
}

snyk_code() {
    if [ "$SNYK_ENABLE_CODE_SCAN" != "true" ]; then
        echo "Skipping snyk code scan"
        return 0
    fi
    echo Starting snyk code scan
    PARAMS=(--project-name="$PROJECT_NAME" --org="$ORG_NAME"  --sarif-file-output="${ARTIFACT_DIR}/snyk.sarif.json" --report)
    if [ "$SNYK_CODE_ADDITIONAL_ARGS" ]; then
        read -a PARAMS <<<"$SNYK_CODE_ADDITIONAL_ARGS"
    fi

    if [ -z "${TARGET_REFERENCE}" ]; then
        TARGET_REFERENCE=$(echo $CLONE_REFS | jq -r .base_ref | tr '.' '-')
    fi
    PARAMS+=(--target-reference="${TARGET_REFERENCE}")

    ${SNYK_DIR}/snyk code test "${PARAMS[@]}"
    local rc=$?
    echo Full vulnerabilities report is available at ${ARTIFACT_DIR}/snyk.sarif.json
    return $rc
}

pre_execution_hook_cmd() {
    local rc=0
    echo "Running pre-execution hook"
    if [ "$SNYK_PRE_EXECUTION_HOOK_CMD" ]; then
        eval "$SNYK_PRE_EXECUTION_HOOK_CMD"
        rc=$?
    else
        echo "No pre-execution hook defined"
    fi
    echo "Pre-execution hook completed"
    return "$rc"
}

pre_execution_hook_script() {
    local rc=0
    echo "Running pre-execution hook script"
    if [ "$SNYK_PRE_EXECUTION_HOOK_SCRIPT" ] && [ -f "$SNYK_PRE_EXECUTION_HOOK_SCRIPT" ]; then
        # shellcheck source=/dev/null
        source "$SNYK_PRE_EXECUTION_HOOK_SCRIPT"
        rc=$?
    else
        echo "No pre-execution hook script defined"
    fi
    echo "Pre-execution hook script completed"
    return "$rc"
}

declare -a cmd_order=(
    pre_execution_hook_cmd
    pre_execution_hook_script
    snyk_deps
    snyk_code
)

declare -a error_messages=(
    "pre-execution hook command failed"
    "pre-execution hook script failed"
    "snyk dependencies scan failed"
    "snyk code scan failed"
)

all_successful=true
for idx in "${!cmd_order[@]}"; do
    if ! ${cmd_order[idx]}; then
        all_successful=false
        echo "${error_messages[idx]}"
    fi
done

if [ "$all_successful" = "false" ]; then
    exit 1
fi
