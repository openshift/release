#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

function deploy_jaeger() {
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: jaeger-product
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: jaeger-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
}

function deploy_kiali_operator() {
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kiali-ossm
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kiali-ossm 
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
}

function deploy_servicemesh_operator() {
  oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: servicemeshoperator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: servicemeshoperator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
}

function get_csv_info() {
  oc get subscription jaeger-product -n openshift-operators -o yaml | grep currentCSV
  oc get subscription kiali-ossm -n openshift-operators -o yaml | grep currentCSV
  oc get subscription servicemeshoperator -n openshift-operators -o yaml | grep currentCSV
}

function main() {
  deploy_jaeger
  deploy_kiali_operator
  deploy_servicemesh_operator
  sleep 180
  get_csv_info
}

main