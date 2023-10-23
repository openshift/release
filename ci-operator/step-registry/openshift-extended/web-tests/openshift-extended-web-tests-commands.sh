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
## determine if running against managed service or smoke scenarios
if [[ ($E2E_RUN_TAGS == *"@osd_ccs"*) || ($E2E_RUN_TAGS == *"@rosa"*) ]]; then
  echo "Testing against online cluster"
  ./console-test-osd.sh || exit 0
elif [[ $E2E_RUN_TAGS == *"@smoke"* ]]; then
  echo "only run smoke scenarios"
  ./console-test-frontend.sh --tags @smoke || exit 0
fi

## determine if it is hypershift guest cluster or not
res=0
oc get node --kubeconfig=${KUBECONFIG} | grep master || res=$?
if [ $res -eq 0 ]; then
  echo "Testing on normal cluster"
  ./console-test-frontend.sh || exit 0
else
  echo "Testing on hypershift guest cluster"
  ./console-test-frontend-hypershift.sh || exit 0
fi
