#!/usr/bin/env bash

date 

oc get pods -n openshift-marketplace 
pod_names=$( oc get pods -n openshift-marketplace --no-headers | awk '{print $1}')
echo "$pod_names" | while IFS= read -r pod; do
    echo "pod name $pod"
    oc logs $pod -n openshift-marketplace >> "${ARTIFACT_DIR}/logs_$pod.out"
    oc describe pod $pod -n openshift-marketplace >> "${ARTIFACT_DIR}/desc_$pod.out"
done

oc get catalogsource -n openshift-marketplace -o yaml

oc get packagemanifest -n openshift-marketplace

oc adm inspect ns openshift-cnv

oc get subscription -n openshift-cnv -o yaml

mkdir -p ${ARTIFACT_DIR}/must-gather

export EXTRA_MG_ARGS="--image=quay.io/kubevirt/must-gather"

oc --insecure-skip-tls-verify adm must-gather --dest-dir "${ARTIFACT_DIR}/must-gather" ${EXTRA_MG_ARGS} > "${ARTIFACT_DIR}/must-gather/must-gather.log"

tar -czC "${ARTIFACT_DIR}/must-gather" -f "${ARTIFACT_DIR}/must-gather.tar.gz" .