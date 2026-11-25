#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# get all private subnets name from machinesets, then replace "private" with "public" to generate the public subnets name
# this way is available for IPI installer created VPC
public_subnets=$(oc -n openshift-machine-api get machinesets.machine.openshift.io -ojsonpath='{.items[*].spec.template.spec.providerSpec.value.subnet.filters[].values}' | tr -d "[]" | sed 's/ /,/g' | sed 's/subnet-private/subnet-public/g')
echo "public subnets: $public_subnets"

lb_type=$(oc get ingress.config cluster -ojsonpath='{.spec.loadBalancer.platform.aws.type}')
echo "load balancer type: $lb_type"

case "$lb_type" in
    "Classic")
        oc -n openshift-ingress-operator patch ingresscontroller/default --type=merge -p '{"spec":{"endpointPublishingStrategy":{"type":"LoadBalancerService","loadBalancer":{"providerParameters":{"type":"AWS","aws":{"type":"Classic","classicLoadBalancer":{"subnets":{"ids":null,"names":['"$public_subnets"']}}}},"scope":"External"}}}}'
        ;;
    "NLB")
        oc -n openshift-ingress-operator patch ingresscontroller/default --type=merge -p '{"spec":{"endpointPublishingStrategy":{"type":"LoadBalancerService","loadBalancer":{"providerParameters":{"type":"AWS","aws":{"type":"NLB","networkLoadBalancer":{"subnets":{"ids":null,"names":['"$public_subnets"']}}}},"scope":"External"}}}}'
        ;;
    *)
        echo "Unknown load balancer type"
        exit 1
        ;;
esac

oc -n openshift-ingress delete svc router-default

echo "$(date -u --rfc-3339=seconds) - Waiting for clusteroperators to complete"
oc wait clusteroperators --all \
    --for=condition=Available=True \
    --for=condition=Progressing=False \
    --for=condition=Degraded=False \
    --timeout=10m
echo "$(date -u --rfc-3339=seconds) - All clusteroperators are available now"

oc -n openshift-ingress-operator get ingresscontroller default -oyaml
oc -n openshift-ingress get svc router-default -oyaml
