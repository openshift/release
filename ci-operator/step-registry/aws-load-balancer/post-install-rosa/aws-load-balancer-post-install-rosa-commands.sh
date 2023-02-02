#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=> get albo catalog source"
oc -n aws-load-balancer-operator get catalogsource -o yaml
echo "=> get albo operatorgroup"
oc -n aws-load-balancer-operator get operatorgroup -o yaml
echo "=> get albo subscription"
oc -n aws-load-balancer-operator get subscription -o yaml || true
echo "=> get albo installplan"
oc -n aws-load-balancer-operator get installplan -o yaml || true
echo "=> get albo pods"
oc -n aws-load-balancer-operator get pods -o yaml
for p in $(oc  -n aws-load-balancer-operator get pods --template='{{range .items}}{{.metadata.name}} {{end}}'); do
    echo "=> logs for albo pod ${p}"
    oc -n aws-load-balancer-operator logs "${p}" || true
    echo "=> describe for albo pod ${p}"
    oc -n aws-load-balancer-operator describe pod "${p}" || true
done
echo "=> get albo services"
oc -n aws-load-balancer-operator get svc -o yaml
echo "=> get albo endpoints"
oc -n aws-load-balancer-operator get endpoints -o yaml
echo "=> get albo secret"
oc -n aws-load-balancer-operator get secret
echo "=> get awsloadbalancercontrollers"
if oc get crd | grep -q awsloadbalancercontrollers; then
    oc get awsloadbalancercontrollers -o yaml
fi
echo "=> all done!"
