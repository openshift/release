#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco cluster setup command ************"
# Fix user IDs in a container
~/fix_uid.sh

export MAINENV="$SHARED_DIR/main.env"

echo "# THERE IS THE ENVS FILE FOR JOBS" > $MAINENV
echo "export DEBUG_PROW_JOB_ID=${PROW_JOB_ID}" >> $MAINENV
echo "export DEBUG_JOB_NAME=${JOB_NAME}" >> $MAINENV
echo "export DEBUG_JOB_TYPE=${JOB_TYPE}" >> $MAINENV
echo "export DEBUG_RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST-}" >> $MAINENV
echo "#######################################################" >> $MAINENV

# Possible values for T5_JOB_TRIGGER: nightly, periodic, rehearse
# Possible values for T5CI_JOB_TYPE: origintests, cnftests
# Possible values for T5CI_VERSION: 4.11, 4.12, 4.13 etc
# Possible values for T5_JOB_DESC: nightly-origintests, periodic-cnftests, rehearse-cnftests etc
# Possible values for T5_JOB_DESC_FULL: nightly-origintests-4.11, periodic-cnftests-4.12, rehearse-cnftests-4.13 etc

if [[ "$PROW_JOB_ID" = *"nightly"* ]] && [[ "$JOB_TYPE" == "periodic" ]]; then
    T5_JOB_TRIGGER="nightly"
    T5_JOB_DESC="nightly-${T5CI_JOB_TYPE}"
    T5_JOB_DESC_FULL="nightly-${T5CI_JOB_TYPE}-${T5CI_VERSION}"
    if [[ -n "${RELEASE_IMAGE_LATEST-}" ]]; then
        export IMG=${RELEASE_IMAGE_LATEST-}
    elif [[ -n "${RELEASE_IMAGE_INITIAL-}" ]]; then
        export IMG=${RELEASE_IMAGE_INITIAL-}
    else
        export IMG=${PROW_JOB_ID/-telco5g/}
    fi
    T5_JOB_IMAGE=${IMG}
    # In case of running on nightly releases we need to figure out what release exactly to use
    KCLI_PARAM="-P openshift_image=registry.ci.openshift.org/ocp/release:${T5_JOB_IMAGE}"
elif [[ "$JOB_TYPE" == "periodic" ]]; then
    T5_JOB_TRIGGER="periodic"
    T5_JOB_DESC="periodic-${T5CI_JOB_TYPE}"
    T5_JOB_DESC_FULL="periodic-${T5CI_JOB_TYPE}-${T5CI_VERSION}"
    KCLI_PARAM="-P tag=${T5CI_VERSION} -P version=nightly"
elif [[ "$JOB_TYPE" == "presubmit" ]] || [[ "$JOB_NAME" == *"rehears"* ]]; then
    T5_JOB_TRIGGER="rehearse"
    T5_JOB_DESC="rehearse-${T5CI_JOB_TYPE}"
    T5_JOB_DESC_FULL="rehearse-${T5CI_JOB_TYPE}-${T5CI_VERSION}"
    KCLI_PARAM="-P tag=${T5CI_VERSION} -P version=nightly"
    PULL_URL="https://github.com/${REPO_OWNER-}/${REPO_NAME-}/pull/${PULL_NUMBER-}"
    PULL_API_URL="https://api.github.com/repos/${REPO_OWNER-}/${REPO_NAME-}/pulls/${PULL_NUMBER-}"
fi

# Cluster to use for cnf-tests, and to exclude from selection in other jobs
PREPARED_CLUSTER="cnfdu1"
# Set environment for jobs to run
# Internal - allow to run jobs on D/S lab
INTERNAL=true
# Internal_only - run jobs on D/S lab only
INTERNAL_ONLY=true
# Whether to use the bastion environment (required for U/S lab)
# Will be calculated in cluster-setup step based on the allocated cluster type
BASTION_ENV=true
# Environment - US lab "upstreambil" or D/S lab "internalbos" or "any"
CL_SEARCH="upstreambil"
# Run cnftests jobs on Upstream lab only
if [[ "$T5CI_JOB_TYPE" == "cnftests" ]]; then
    INTERNAL=false
    INTERNAL_ONLY=false
fi
# Find out what should be clusters lab
if $INTERNAL_ONLY && $INTERNAL; then
    CL_SEARCH="internalbos"
elif $INTERNAL; then
    CL_SEARCH="any"
fi

GET_CLUSTER_ARGS=""
if [[ "$T5_JOB_DESC" == "periodic-cnftests" ]]; then
  GET_CLUSTER_ARGS="--cluster-name $PREPARED_CLUSTER --force"
else
  GET_CLUSTER_ARGS="-e $CL_SEARCH --exclude $PREPARED_CLUSTER"
fi

# Custom logic for jobs that need to run on specific clusters or job types
##### put it here, for example:
# T5_JOB_TRIGGER="periodic"
# T5_JOB_DESC="periodic-${T5CI_JOB_TYPE}"
# T5_JOB_DESC_FULL="periodic-${T5CI_JOB_TYPE}-${T5CI_VERSION}"
# T5_JOB_IMAGE="4.11.0-0.nightly-2023-02-22-220245"
# KCLI_PARAM="-P openshift_image=registry.ci.openshift.org/ocp/release:${T5_JOB_IMAGE}"
# KCLI_PARAM="-P tag=${T5CI_VERSION} -P version=nightly"
# PREPARED_CLUSTER="cnfdu1"
# INTERNAL=false
# INTERNAL_ONLY=false
# PULL_URL="https://github.com/openshift/release/pull/36665"
# PULL_API_URL="https://api.github.com/repos/openshift/release/pulls/36665"

##############################################################3
echo "# JOB DEFINITIONS AND OPTIONS" > $MAINENV
echo "export T5_JOB_TRIGGER=${T5_JOB_TRIGGER}" >> $MAINENV
echo "export T5_JOB_DESC=${T5_JOB_DESC}" >> $MAINENV
echo "export T5_JOB_DESC_FULL=${T5_JOB_DESC_FULL}" >> $MAINENV
echo "export T5_JOB_IMAGE=${T5_JOB_IMAGE-}" >> $MAINENV  # can be unset
echo "export KCLI_PARAM=\"${KCLI_PARAM}\"" >> $MAINENV
echo "export PREPARED_CLUSTER=${PREPARED_CLUSTER}" >> $MAINENV
echo "export INTERNAL=${INTERNAL}" >> $MAINENV
echo "export INTERNAL_ONLY=${INTERNAL_ONLY}" >> $MAINENV
echo "export BASTION_ENV=${BASTION_ENV}" >> $MAINENV
echo "export CL_SEARCH=${CL_SEARCH}" >> $MAINENV
echo "export GET_CLUSTER_ARGS=\"${GET_CLUSTER_ARGS}\"" >> $MAINENV
echo "export PULL_URL=${PULL_URL-}" >> $MAINENV  # can be unset
echo "export PULL_API_URL=${PULL_API_URL-}" >> $MAINENV  # can be unset

cp $MAINENV $ARTIFACT_DIR/main.env
