#!/bin/bash
set -euo pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# Expected configuration
expected_tls_version="VersionTLS13"
expected_ciphers='["TLS_AES_128_GCM_SHA256","TLS_AES_256_GCM_SHA384","TLS_CHACHA20_POLY1305_SHA256"]'

# Normalize JSON array to a sorted string for comparison
normalize() {
  echo "$1" | jq -S . | tr -d '\n '
}

check_component() {
  local name="$1"
  local json_path="$2"
  local config_json

  echo "Checking $name..."

  config_json=$(eval "$json_path")
  if [[ -z "$config_json" ]]; then
    echo "Failed to retrieve config for $name"
    return 1
  fi

  # Extract and normalize
  actual_tls_version=$(echo "$config_json" | jq -r '.minTLSVersion')
  actual_ciphers=$(normalize "$(echo "$config_json" | jq '.cipherSuites')")

  expected_ciphers_normalized=$(normalize "$expected_ciphers")

  # Compare
  if [[ "$actual_tls_version" != "$expected_tls_version" ]]; then
    echo "$name - Unexpected TLS version: $actual_tls_version"
  elif [[ "$actual_ciphers" != "$expected_ciphers_normalized" ]]; then
    echo "$name - Unexpected cipher suites:"
    echo "Actual:   $actual_ciphers"
    echo "Expected: $expected_ciphers_normalized"
  else
    echo "$name - TLS settings are as expected."
  fi
}

oc login -u kubeadmin "$(oc whoami --show-server=true)" < "$SHARED_DIR/kubeadmin-password"

oc patch apiservers/cluster --type=merge -p '{"spec": {"tlsSecurityProfile":{"modern":{},"type":"Modern"}}}'

# Wait for cluster operators to start rolling out because of tls Security Profile change
sleep 3m

oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=30m

oc get apiservers/cluster -oyaml | tee "$SHARED_DIR"/apiserver.config
oc get openshiftapiservers.operator.openshift.io cluster -o json | tee -a "$SHARED_DIR"/apiserver.config

# Define components to check
check_component "OpenShift APIServer" \
  "oc get openshiftapiservers.operator.openshift.io cluster -o json | jq '.spec.observedConfig.servingInfo'"

check_component "Kube APIServer" \
  "oc get kubeapiservers.operator.openshift.io cluster -o json | jq '.spec.observedConfig.servingInfo'"

check_component "Authentication ConfigMap" \
  "oc get cm -n openshift-authentication v4-0-config-system-cliconfig -o jsonpath='{.data.v4\\-0\\-config\\-system\\-cliconfig}' | jq '.servingInfo'"
