#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

release_stream_pullspec() {
    local version="$1"
    local url="https://amd64.ocp.releases.ci.openshift.org/api/v1/releasestream/${version}.0-0.nightly/latest"
    local response http body pullspec
    if ! response=$(curl -q -L -sS --retry 5 --retry-delay 10 -w $'\n%{http_code}' "$url"); then
        echo "ERROR: could not query the OCP release stream ${version}.0-0.nightly" >&2
        echo "       ${url}" >&2
        return 1
    fi
    http="${response##*$'\n'}"
    body="${response%$'\n'*}"
    if [[ "$http" != "200" ]]; then
        echo "ERROR: OCP release stream ${version}.0-0.nightly is not available (HTTP ${http})" >&2
        printf '       %s\n' "$body" >&2
        echo "       ${url}" >&2
        return 1
    fi
    if ! pullspec=$(jq -er '.pullSpec' <<<"$body" 2>/dev/null) || [[ -z "$pullspec" ]]; then
        echo "ERROR: OCP release stream ${version}.0-0.nightly did not return a pullSpec" >&2
        printf '       %s\n' "$body" >&2
        echo "       ${url}" >&2
        return 1
    fi
    printf '%s\n' "$pullspec"
}

echo "************ telco cluster setup command ************"
# Fix user IDs in a container
[ -e "$HOME/fix_uid.sh" ] && "$HOME/fix_uid.sh" || echo "$HOME/fix_uid.sh was not found" >&2

export MAINENV="$SHARED_DIR/main.env"

echo "# THERE IS THE ENVS FILE FOR JOBS" > "$MAINENV"
echo "export DEBUG_T5CI_JOB_TYPE='${T5CI_JOB_TYPE}'" >> "$MAINENV"
echo "export DEBUG_T5CI_VERSION='${T5CI_VERSION}'" >> "$MAINENV"
echo "export DEBUG_PROW_JOB_ID='${PROW_JOB_ID}'" >> "$MAINENV"
echo "export DEBUG_JOB_NAME='${JOB_NAME}'" >> "$MAINENV"
echo "export DEBUG_JOB_TYPE='${JOB_TYPE}'" >> "$MAINENV"
echo "export DEBUG_RELEASE_IMAGE_LATEST='${RELEASE_IMAGE_LATEST-}'" >> "$MAINENV"
echo "export GIT_COMMITTER_NAME='CI User'" >> "$MAINENV"
echo "export GIT_COMMITTER_EMAIL='cnf-devel@redhat.com'" >> "$MAINENV"
echo "export REPO_OWNER=${REPO_OWNER:-''}" >> "$MAINENV"
echo "export REPO_NAME=${REPO_NAME:-''}" >> "$MAINENV"
echo "export PULL_URL=${PULL_URL:-''}" >> "$MAINENV"
echo "export PR_URLS=${PR_URLS:-''}" >> "$MAINENV"
echo "export PULL_BASE_REF=${PULL_BASE_REF:-''}" >> "$MAINENV"
echo "# Reconnect instead of failing the play when SSH to the lab hosts drops for a while" >> "$MAINENV"
echo "export ANSIBLE_SSH_RETRIES=15" >> "$MAINENV"
echo "export ANSIBLE_TIMEOUT=30" >> "$MAINENV"
echo "#######################################################" >> "$MAINENV"

if [[ "$PROW_JOB_ID" = *"nightly"* ]] && [[ "$JOB_TYPE" == "periodic" ]]; then
    if [[ -n "${RELEASE_IMAGE_LATEST-}" ]]; then
        export IMG=${RELEASE_IMAGE_LATEST-}
    elif [[ -n "${RELEASE_IMAGE_INITIAL-}" ]]; then
        export IMG=${RELEASE_IMAGE_INITIAL-}
    else
        export IMG=${PROW_JOB_ID/-telco5g/}
    fi
    if [[ "$IMG" == "5"* ]]; then
        IMG_URL="registry.ci.openshift.org/ocp/release-5:$IMG"
    else
        IMG_URL="registry.ci.openshift.org/ocp/release:$IMG"
    fi

    echo "export T5_JOB_TRIGGER=nightly" >> "$MAINENV"
    echo "export T5_JOB_DESC='nightly-${T5CI_JOB_TYPE}'" >> "$MAINENV"
    echo "export T5_JOB_DESC_FULL='nightly-${T5CI_JOB_TYPE}-${T5CI_VERSION}'" >> "$MAINENV"
    echo "# In case of running on nightly releases we need to figure out what release exactly to use" >> "$MAINENV"
    echo "export T5_JOB_RELEASE_IMAGE='$IMG_URL'" >> "$MAINENV"
    echo "export T5_JOB_RELEASE_IMAGE_TAG='$IMG'" >> "$MAINENV"
    echo "export KCLI_PARAM='-P openshift_image=$IMG_URL'" >> "$MAINENV"
    echo "export SNO_PARAM='-f ${IMG}'" >> "$MAINENV"
elif [[ "$JOB_TYPE" == "periodic" ]]; then
    if ! IMG_URL=$(release_stream_pullspec "$T5CI_VERSION"); then
        echo "ERROR: no OCP release ${T5CI_VERSION}.0-0.nightly is available to install; refusing to start" >&2
        exit 1
    fi

    echo "export T5_JOB_TRIGGER=periodic" >> "$MAINENV"
    echo "export T5_JOB_DESC='periodic-${T5CI_JOB_TYPE}'" >> "$MAINENV"
    echo "export T5_JOB_DESC_FULL='periodic-${T5CI_JOB_TYPE}-${T5CI_VERSION}'" >> "$MAINENV"
    echo "export T5_JOB_RELEASE_IMAGE='$IMG_URL'" >> "$MAINENV"
    echo "export KCLI_PARAM='-P tag=${T5CI_VERSION} -P version=nightly'" >> "$MAINENV"
    echo "export SNO_PARAM='-t ${T5CI_VERSION} -r nightly'" >> "$MAINENV"
elif [[ "$JOB_TYPE" == "presubmit" ]] || [[ "$JOB_NAME" == *"rehears"* ]]; then
    if ! IMG_URL=$(release_stream_pullspec "$T5CI_VERSION"); then
        echo "ERROR: no OCP release ${T5CI_VERSION}.0-0.nightly is available to install; refusing to start" >&2
        exit 1
    fi

    echo "export T5_JOB_TRIGGER=rehearse" >> "$MAINENV"
    echo "export T5_JOB_DESC=rehearse-${T5CI_JOB_TYPE}" >> "$MAINENV"
    echo "export T5_JOB_DESC_FULL=rehearse-${T5CI_JOB_TYPE}-${T5CI_VERSION}" >> "$MAINENV"
    echo "export T5_JOB_RELEASE_IMAGE='$IMG_URL'" >> "$MAINENV"
    echo "export KCLI_PARAM='-P tag=${T5CI_VERSION} -P version=nightly'" >> "$MAINENV"
    echo "export SNO_PARAM='-t ${T5CI_VERSION} -r nightly'" >> "$MAINENV"
    echo "export PULL_URL='https://github.com/${REPO_OWNER-}/${REPO_NAME-}/pull/${PULL_NUMBER-}'" >> "$MAINENV"
    echo "export PULL_API_URL='https://api.github.com/repos/${REPO_OWNER-}/${REPO_NAME-}/pulls/${PULL_NUMBER-}'" >> "$MAINENV"
fi

cp "$MAINENV" "$ARTIFACT_DIR/main.env"
