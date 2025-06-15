#!/bin/bash
set -euo pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

expected_tls_version="VersionTLS13"
expected_ciphers='["TLS_AES_128_GCM_SHA256","TLS_AES_256_GCM_SHA384","TLS_CHACHA20_POLY1305_SHA256"]'

components=(
  "kube-apiserver|openshift-kube-apiserver|apiserver|6443"
  "openshift-apiserver|openshift-apiserver|none|8443"
  "authentication|openshift-authentication|none|6443"
  "kube-controller-manager|openshift-kube-controller-manager|app=kube-controller-manager|10257"
  "kube-scheduler|openshift-kube-scheduler|app=openshift-kube-scheduler|10259"
  "etcd|openshift-etcd|app=etcd|2379"
)

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

  actual_tls_version=$(echo "$config_json" | jq -r '.minTLSVersion')
  actual_ciphers=$(normalize "$(echo "$config_json" | jq '.cipherSuites')")

  expected_ciphers_normalized=$(normalize "$expected_ciphers")

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

check_tls13_openssl() {
  local name="$1"
  local namespace="$2"
  local selector="$3"
  local remote_port="$4"

  echo "=> [$name] Checking pod in $namespace with selector: $selector"

  oc project "$namespace" >/dev/null 2>&1 || true

  if [[ "$selector" == "none" ]]; then
    pod=$(oc get pod -n "$namespace" --no-headers | sed -n '1p' | awk '{print $1}')
  else
    pod=$(oc get pod -n "$namespace" -l "$selector" --no-headers | sed -n '1p' | awk '{print $1}')
  fi

  if [[ -z "$pod" ]]; then
    echo "$name: No pod found"
    return
  fi

  local_port=$(shuf -i 9000-10000 -n 1)
  echo "=> Port-forwarding $pod $remote_port → localhost:$local_port"
  oc port-forward -n "$namespace" "$pod" "$local_port:$remote_port" >/dev/null 2>&1 &
  pf_pid=$!

  max_retries=5
  retry_delay=3
  attempt=1

  sleep ${retry_delay}

  until nc -z localhost "$local_port"; do
    if (( attempt >= max_retries )); then
      echo "Warning: $name: Port-forward failed after $max_retries attempts"
      kill $pf_pid 2>/dev/null
      wait $pf_pid 2>/dev/null || true
      return
    fi
    echo "[$name] Waiting for port-forward... attempt $attempt/$max_retries"
    sleep $retry_delay
    ((attempt++))
  done

  output=$(echo | openssl s_client -connect localhost:$local_port -tls1_3 2>/dev/null | grep -E 'Protocol|Cipher')

  if echo "$output" | grep -q 'TLSv1.3'; then
    echo "=> $name: $(echo "$output" | paste -sd ' | ' -)"
  else
    echo "X> $name: TLS 1.3 not supported or connection failed"
  fi

  kill $pf_pid 2>/dev/null
  wait $pf_pid 2>/dev/null || true
  sleep 1
}

oc patch apiservers/cluster --type=merge -p '{"spec": {"tlsSecurityProfile":{"modern":{},"type":"Modern"}}}'

# Wait for cluster operators to start rolling out because of tls Security Profile change
sleep 3m

oc adm wait-for-stable-cluster --minimum-stable-period=3m --timeout=60m

check_component "OpenShift APIServer" \
  "oc get openshiftapiservers.operator.openshift.io cluster -o json | jq '.spec.observedConfig.servingInfo'"

check_component "Kube APIServer" \
  "oc get kubeapiservers.operator.openshift.io cluster -o json | jq '.spec.observedConfig.servingInfo'"

check_component "Authentication" \
  "oc get authentications.operator.openshift.io cluster -o json | jq '.spec.observedConfig.oauthServer.servingInfo'"

check_component "OpneShift Etcd" \
  "oc get etcds.operator.openshift.io cluster -o json | jq '.spec.observedConfig.servingInfo'"

check_component "OpneShift Kube-ControllerManagers" \
  "oc get kubecontrollermanagers.operator.openshift.io cluster -ojson  | jq '.spec.observedConfig.servingInfo'"

check_component "OpneShift Kube-Scheduler" \
  "oc get kubeschedulers.operator.openshift.io cluster -o json | jq '.spec.observedConfig.servingInfo'"

echo
echo "Checking TLS 1.3 support and cipher suite on OpenShift components..."

for entry in "${components[@]}"; do
  IFS='|' read -r name ns selector port <<< "$entry"
  check_tls13_openssl "$name" "$ns" "$selector" "$port"
  echo
done

