#!/usr/bin/env bash

set -ex

oc patch etcd cluster -p='{"spec": {"unsupportedConfigOverrides": {"    useUnsupportedUnsafeNonHANonProductionUnstableEtcd": true}}}' --type=merge
oc patch authentications.operator.openshift.io cluster -p='{"spec": {"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableOAuthServer": true}}}' --type=merge

oc scale --replicas=1 ingresscontroller/default -n openshift-ingress-operator
oc scale --replicas=1 deployment.apps/console -n openshift-console
oc scale --replicas=1 deployment.apps/downloads -n openshift-console
oc scale --replicas=1 deployment.apps/oauth-openshift -n openshift-authentication
oc scale --replicas=1 deployment.apps/packageserver -n openshift-operator-lifecycle-manager

# Scale down CMO to avoid recreation of resources, before deleting openshift-monitoring project
oc scale --replicas=0 deployment.apps/cluster-monitoring-operator -n openshift-monitoring
oc delete project openshift-monitoring
