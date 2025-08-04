#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail



cp -L $KUBECONFIG /tmp/kubeconfig

export KUBECONFIG=/tmp/kubeconfig

oc whoami
#create multiclusterhub instance

oc create -f - <<EOF
        apiVersion: operator.open-cluster-management.io/v1
        kind: MultiClusterHub
        metadata:
            name: multiclusterhub
            namespace: ocm
        spec:
            localClusterName: local-cluster
EOF
oc wait  MultiClusterHub -n ocm multiclusterhub --for=condition=Available --timeout=15m
oc create -f - <<EOF
        kind: HyperConverged
        apiVersion: hco.kubevirt.io/v1beta1
        metadata:
            annotations:
                deployOVS: 'false'
            name: kubevirt-hyperconverged
            namespace: openshift-cnv
        spec: {}
EOF

oc wait hyperconverged -n openshift-cnv kubevirt-hyperconverged --for=condition=Available --timeout=15m
sleep 7200