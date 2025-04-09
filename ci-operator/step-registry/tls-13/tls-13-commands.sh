#!/bin/bash
set -euo pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

oc patch apiservers/cluster --type=merge -p '{"spec": {"tlsSecurityProfile":{"modern":{},"type":"Modern"}}}'

oc adm wait-for-stable-cluster