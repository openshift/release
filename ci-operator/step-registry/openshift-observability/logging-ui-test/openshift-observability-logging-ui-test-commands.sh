#!/bin/bash

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

## skip all tests when console is not installed
if ! (oc get clusteroperator console --kubeconfig=${KUBECONFIG}) ; then
    echo "console is not installed, skipping all console tests."
    exit 0
fi

## skip all if COO is not installed
coo_ready=$(oc get pod -n openshift-cluster-observability-operator -l app.kubernetes.io/name=observability-operator -o name)
if [[ $coo_ready == "" ]]  ; then
    echo "COO is not installed, skipping all console tests."
    exit 0
fi

## Add dev console in 4.19
openshift_version=$(oc version -o json |jq -r '.openshiftVersion')

if [[ ${openshift_version} =~ 4.19 ]]; then
    echo " Enable DevConosle"
    oc patch console.operator cluster -p '{"spec":{"customization":{"perspectives":[{"id":"dev","visibility":{"state":"Enabled"}}]}}}' --type merge
fi

pwd && ls -ltr
cd web && npm run dev
