#!/usr/bin/env bash

set -x

oc create namespace openshift-gitops-operator
oc get ns openshift-gitops-operator -o yaml
operator-sdk run bundle --security-context-config restricted -openshift-gitops-operator "$OO_BUNDLE"
oc wait --for condition=Available -n openshift-gitops-operator deployment openshift-gitops-operator-controller-manager