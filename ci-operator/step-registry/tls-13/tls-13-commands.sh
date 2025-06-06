#!/bin/bash
set -euo pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

oc login -u kubeadmin "$(oc whoami --show-server=true)" < "$SHARED_DIR/kubeadmin-password"

oc patch apiservers/cluster --type=merge -p '{"spec": {"tlsSecurityProfile":{"modern":{},"type":"Modern"}}}'

# Wait for cluster operators to start rolling out because of tls Security Profile change
sleep 3m

oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=30m

oc get apiservers/cluster -oyaml | tee "$SHARED_DIR"/apiserver.config
oc get openshiftapiservers.operator.openshift.io cluster -o json | tee -a "$SHARED_DIR"/apiserver.config

