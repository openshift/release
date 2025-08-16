#!/usr/bin/env bash

echo "export BUNDLE_IMAGE=registry.redhat.io/kueue/kueue-operator-bundle:${RELEASE_TAG}" >> "${SHARED_DIR}/env"

oc create namespace openshift-kueue-operator || true
oc label ns openshift-kueue-operator openshift.io/cluster-monitoring=true --overwrite
