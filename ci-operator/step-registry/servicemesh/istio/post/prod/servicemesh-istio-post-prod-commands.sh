#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

oc get subscription jaeger-product -n openshift-operators -o yaml | grep currentCSV
oc get subscription kiali-ossm -n openshift-operators -o yaml | grep currentCSV
oc get subscription servicemeshoperator -n openshift-operators -o yaml | grep currentCSV

oc delete subscription jaeger-product -n openshift-operators
oc delete subscription kiali-ossm -n openshift-operators
oc delete subscription servicemeshoperator -n openshift-operators

#oc delete clusterserviceversion -n openshift-operators --all