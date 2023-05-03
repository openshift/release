#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco cluster setup command ************"
# Fix user IDs in a container
~/fix_uid.sh

export MAINENV="$SHARED_DIR/main.env"

echo "# THERE IS THE ENVS FILE FOR JOBS" > $MAINENV
echo "export DEBUG_T5CI_JOB_TYPE=${T5CI_JOB_TYPE}" >> $MAINENV
echo "export DEBUG_T5CI_VERSION=${T5CI_VERSION}" >> $MAINENV
echo "export DEBUG_PROW_JOB_ID=${PROW_JOB_ID}" >> $MAINENV
echo "export DEBUG_JOB_NAME=${JOB_NAME}" >> $MAINENV
echo "export DEBUG_JOB_TYPE=${JOB_TYPE}" >> $MAINENV
echo "export DEBUG_RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST-}" >> $MAINENV
echo "export GIT_COMMITTER_NAME='CI User'" >> $MAINENV
echo "export GIT_COMMITTER_EMAIL='cnf-devel@redhat.com'" >> $MAINENV
echo "#######################################################" >> $MAINENV

if [[ "$PROW_JOB_ID" = *"nightly"* ]] && [[ "$JOB_TYPE" == "periodic" ]]; then
    echo "export T5_JOB_TRIGGER=nightly" >> $MAINENV
    echo "export T5_JOB_DESC=nightly-${T5CI_JOB_TYPE}" >> $MAINENV
    echo "export T5_JOB_DESC_FULL=nightly-${T5CI_JOB_TYPE}-${T5CI_VERSION}" >> $MAINENV
    if [[ -n "${RELEASE_IMAGE_LATEST-}" ]]; then
        export IMG=${RELEASE_IMAGE_LATEST-}
    elif [[ -n "${RELEASE_IMAGE_INITIAL-}" ]]; then
        export IMG=${RELEASE_IMAGE_INITIAL-}
    else
        export IMG=${PROW_JOB_ID/-telco5g/}
    fi
    echo "export T5_JOB_IMAGE=${IMG}" >> $MAINENV
    # In case of running on nightly releases we need to figure out what release exactly to use
    echo "export KCLI_PARAM=\"-P openshift_image=registry.ci.openshift.org/ocp/release:${IMG}\"" >> $MAINENV
elif [[ "$JOB_TYPE" == "periodic" ]]; then
    echo "export T5_JOB_TRIGGER=periodic" >> $MAINENV
    echo "export T5_JOB_DESC=periodic-${T5CI_JOB_TYPE}" >> $MAINENV
    echo "export T5_JOB_DESC_FULL=periodic-${T5CI_JOB_TYPE}-${T5CI_VERSION}" >> $MAINENV
    echo "export KCLI_PARAM=\"-P tag=${T5CI_VERSION} -P version=nightly\"" >> $MAINENV
elif [[ "$JOB_TYPE" == "presubmit" ]] || [[ "$JOB_NAME" == *"rehears"* ]]; then
    echo "export T5_JOB_TRIGGER=rehearse" >> $MAINENV
    echo "export T5_JOB_DESC=rehearse-${T5CI_JOB_TYPE}" >> $MAINENV
    echo "export T5_JOB_DESC_FULL=rehearse-${T5CI_JOB_TYPE}-${T5CI_VERSION}" >> $MAINENV
    echo "export KCLI_PARAM=\"-P tag=${T5CI_VERSION} -P version=nightly\"" >> $MAINENV
    echo "export PULL_URL=https://github.com/${REPO_OWNER-}/${REPO_NAME-}/pull/${PULL_NUMBER-}" >> $MAINENV
    echo "export PULL_API_URL=https://api.github.com/repos/${REPO_OWNER-}/${REPO_NAME-}/pulls/${PULL_NUMBER-}" >> $MAINENV
fi
cp $MAINENV $ARTIFACT_DIR/main.env
