#!/bin/bash
set -euo pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

oc login -u kubeadmin "$(oc whoami --show-server=true)" < "$SHARED_DIR/kubeadmin-password"

oc patch apiservers/cluster --type=merge -p '{"spec": {"tlsSecurityProfile":{"modern":{},"type":"Modern"}}}'

oc adm wait-for-stable-cluster