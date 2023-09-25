#!/bin/bash
#job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
#job="${job#nightly-}"
#exec .openshift-ci/dispatch.sh "${job}"

echo CLUSTER_PROFILE_DIR=$CLUSTER_PROFILE_DIR
echo ARTIFACT_DIR=$ARTIFACT_DIR
echo ARTIFACT=$ARTIFACT
echo CLUSTER_NAME=${CLUSTER_NAME}

