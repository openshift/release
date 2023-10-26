#!/bin/bash

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

pwd && ls -ltr
cd frontend || exit 0
pwd && ls -ltr

## skip all tests when console is not installed
if ! (oc get clusteroperator console --kubeconfig=${KUBECONFIG}) ; then
  echo "console is not installed, skipping all console tests."
  exit 0
fi

## determine if it is hypershift guest cluster or not
if ! (oc get node --kubeconfig=${KUBECONFIG} | grep master) ; then
  echo "Testing on hypershift guest cluster"
  ./console-test-frontend-hypershift.sh || true
else
  export E2E_RUN_TAGS="${E2E_RUN_TAGS}"
  echo "E2E_RUN_TAGS is: ${E2E_RUN_TAGS}"
  ## determine if running against managed service or smoke scenarios
  if [[ $E2E_RUN_TAGS =~ @osd_ccs|@rosa ]] ; then
    echo "Testing against online cluster"
    ./console-test-osd.sh || true
  # if the TAGS contains @console, then it's a job specific for UI, run full tests
  # or else, we run smoke tests to balance coverage and cost
  elif [[ $E2E_RUN_TAGS =~ @console ]]; then
    echo "Testing on normal cluster"
    ./console-test-frontend.sh || true
  else
    echo "only run smoke scenarios"
    ./console-test-frontend.sh --tags @smoke || true
  fi
fi
