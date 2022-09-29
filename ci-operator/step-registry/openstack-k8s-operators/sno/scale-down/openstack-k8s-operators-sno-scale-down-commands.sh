#!/usr/bin/env bash

set -ex

oc patch etcd cluster -p='{"spec": {"unsupportedConfigOverrides": {"    useUnsupportedUnsafeNonHANonProductionUnstableEtcd": true}}}' --type=merge
oc patch authentications.operator.openshift.io cluster -p='{"spec": {"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableOAuthServer": true}}}' --type=merge

oc scale --replicas=1 ingresscontroller/default -n openshift-ingress-operator
oc scale --replicas=1 deployment.apps/console -n openshift-console
oc scale --replicas=1 deployment.apps/downloads -n openshift-console
oc scale --replicas=1 deployment.apps/oauth-openshift -n openshift-authentication
oc scale --replicas=1 deployment.apps/packageserver -n openshift-operator-lifecycle-manager

oc scale --replicas=0 deployment.apps/prometheus-{operator,adapter} -n openshift-monitoring
oc scale --replicas=0 deployment.apps/thanos-querier -n openshift-monitoring
oc scale --replicas=0 deployment.apps/telemeter-client -n openshift-monitoring
oc scale --replicas=0 deployment.apps/cluster-monitoring-operator -n openshift-monitoring
oc scale --replicas=0 deployment.apps/{grafana,openshift-state-metrics,kube-state-metrics} -n openshift-monitoring

oc delete project openshift-monitoring
