#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x


ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

if [[ "${E2E_VERSION}" != "default" ]]; then
    git clone "https://github.com/cloud-bulldozer/e2e-benchmarking" /tmp/e2e-benchmarking --branch "${E2E_VERSION}" --depth 1
    pushd /tmp/e2e-benchmarking/workloads/kube-burner-ocp-wrapper
else
    pushd /e2e-benchmarking/workloads/kube-burner-ocp-wrapper
fi

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

# Install the Kueue CR and wait until completion
oc apply -f - <<EOF
apiVersion: kueue.openshift.io/v1
kind: Kueue
metadata:
  name: cluster
  labels:
    app.kubernetes.io/managed-by: kustomize
    app.kubernetes.io/name: kueue-operator
  namespace: openshift-kueue-operator
spec:
  config:
    integrations:
      frameworks:
        - BatchJob
        - Pod
  logLevel: Normal
  operatorLogLevel: Normal
  managementState: Managed
EOF
oc wait Kueue cluster --for=jsonpath='{.status.conditions[?(@.type=="Available")].status}'='True' --timeout=300s

./run.sh
