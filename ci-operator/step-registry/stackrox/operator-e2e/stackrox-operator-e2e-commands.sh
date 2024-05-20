#!/bin/bash
job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"
echo "Allow restricted SCC"
echo oc create clusterrolebinding system:openshift:scc:restricted --clusterrole=system:openshift:scc:restricted --group=system:authenticated
oc create clusterrolebinding system:openshift:scc:restricted --clusterrole=system:openshift:scc:restricted --group=system:authenticated || true
exec .openshift-ci/dispatch.sh "${job}"
