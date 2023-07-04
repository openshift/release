#!/bin/bash

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

pwd && ls -ltr
cd frontend || exit 0
pwd && ls -ltr

## skip all tests when console is not installed
ret=0
oc get co console --kubeconfig=${KUBECONFIG} || ret=$?
if [ $ret -ne 0 ]; then
  echo "console is not installed, skipping all console tests."
  exit 0
fi

export E2E_RUN_TAGS="${E2E_RUN_TAGS}"
echo "E2E_RUN_TAGS is '${E2E_RUN_TAGS}'"
## determine if running against managed service
if [[ ($E2E_RUN_TAGS == *"@osd_ccs"*) || ($E2E_RUN_TAGS == *"@rosa"*) ]]; then
  echo "Testing against online cluster"
  ./console-test-osd.sh || exit 0
fi

## set extra env vars for logging test
export CYPRESS_EXTRA_PARAM="{\"openshift-logging\": {\"cluster-logging\": {\"channel\": \"${CLO_SUB_CHANNEL}\", \"source\": \"${CLO_SUB_SOURCE}\"}, \"elasticsearch-operator\": {\"channel\": \"${EO_SUB_CHANNEL}\", \"source\": \"${EO_SUB_SOURCE}\"}, \"loki-operator\": {\"channel\": \"${LO_SUB_CHANNEL}\", \"source\": \"${LO_SUB_SOURCE}\"}}}"

## determine if it is hypershift guest cluster or not
res=0
oc get node --kubeconfig=${KUBECONFIG} | grep master || res=$?
if [ $res -eq 0 ]; then
  echo "Testing on normal cluster"
  ./console-test-frontend.sh --spec ./tests/logging/ || exit 0
else
  echo "Testing on hypershift guest cluster"
  ./console-test-frontend-hypershift.sh || exit 0
fi
