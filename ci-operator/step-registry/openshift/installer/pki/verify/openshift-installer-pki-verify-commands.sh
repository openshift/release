#!/bin/bash

set -euo pipefail

ARTIFACT_LOG="${ARTIFACT_DIR}/pki-verification.log"
: > "${ARTIFACT_LOG}"

failures=0
total=0

# Signer secrets to verify: "description|secret_name|namespace|cert_key"
declare -a SIGNERS=(
  "root-ca|machine-config-server-ca|openshift-machine-config-operator|tls.crt"
  "kube-apiserver-to-kubelet-signer|kube-apiserver-to-kubelet-signer|openshift-kube-apiserver-operator|tls.crt"
  "kube-apiserver-localhost-signer|localhost-serving-signer|openshift-kube-apiserver-operator|tls.crt"
  "kube-apiserver-service-network-signer|service-network-serving-signer|openshift-kube-apiserver-operator|tls.crt"
  "kube-apiserver-lb-signer|loadbalancer-serving-signer|openshift-kube-apiserver-operator|tls.crt"
  "kube-control-plane-signer|kube-control-plane-signer|openshift-kube-apiserver-operator|tls.crt"
  "aggregator-signer|aggregator-client-signer|openshift-kube-apiserver-operator|tls.crt"
  "etcd-signer|etcd-signer|openshift-etcd|tls.crt"
  "etcd-metrics-signer|etcd-metrics-signer|openshift-etcd|tls.crt"
)

# Map expected algorithm to openssl output strings
case "${EXPECTED_ALGORITHM}" in
  RSA)
    expected_algo_str="rsaEncryption"
    expected_param_str="Public-Key: (${EXPECTED_KEY_PARAM} bit)"
    ;;
  ECDSA)
    expected_algo_str="id-ecPublicKey"
    expected_param_str="ASN1 OID: ${EXPECTED_KEY_PARAM}"
    ;;
  *)
    echo "ERROR: Unsupported EXPECTED_ALGORITHM: ${EXPECTED_ALGORITHM}"
    exit 1
    ;;
esac

echo "============================================="
echo "PKI Verification"
echo "Expected algorithm: ${EXPECTED_ALGORITHM}"
echo "Expected key param: ${EXPECTED_KEY_PARAM}"
echo "============================================="
echo ""

declare -a results=()

for signer in "${SIGNERS[@]}"; do
  IFS='|' read -r description secret_name namespace cert_key <<< "${signer}"
  total=$((total + 1))
  status="PASS"

  echo "--- Checking: ${description} (${namespace}/${secret_name}) ---" | tee -a "${ARTIFACT_LOG}"

  cert_data=""
  cert_data=$(oc get secret "${secret_name}" -n "${namespace}" -o jsonpath="{.data.${cert_key//./\\.}}" 2>&1) || true

  if [[ -z "${cert_data}" ]]; then
    echo "  FAIL: Could not retrieve secret ${namespace}/${secret_name} key ${cert_key}" | tee -a "${ARTIFACT_LOG}"
    results+=("FAIL|${description}|secret not found")
    failures=$((failures + 1))
    continue
  fi

  cert_text=$(echo "${cert_data}" | base64 -d | openssl x509 -text -noout 2>&1) || true

  if [[ -z "${cert_text}" ]]; then
    echo "  FAIL: Could not decode certificate from ${namespace}/${secret_name}" | tee -a "${ARTIFACT_LOG}"
    results+=("FAIL|${description}|cert decode failed")
    failures=$((failures + 1))
    continue
  fi

  # Write full cert details to artifact log
  echo "${cert_text}" >> "${ARTIFACT_LOG}"
  echo "" >> "${ARTIFACT_LOG}"

  # Check algorithm
  algo_match=false
  echo "${cert_text}" | grep -qF "${expected_algo_str}" && algo_match=true || true
  if [[ "${algo_match}" == "true" ]]; then
    echo "  Algorithm: ${expected_algo_str} - OK"
  else
    actual_algo=$(echo "${cert_text}" | grep -F "Public Key Algorithm:" | head -1 | xargs) || true
    echo "  FAIL: Expected algorithm '${expected_algo_str}', got '${actual_algo}'" | tee -a "${ARTIFACT_LOG}"
    status="FAIL"
  fi

  # Check key parameter
  param_match=false
  echo "${cert_text}" | grep -qF "${expected_param_str}" && param_match=true || true
  if [[ "${param_match}" == "true" ]]; then
    echo "  Key param: ${expected_param_str} - OK"
  else
    # Try ECDSA curve OID first (e.g., "ASN1 OID: secp384r1"), fall back to
    # generic key size (e.g., "Public-Key: (2048 bit)") when the cert uses
    # a different algorithm entirely and has no ASN1 OID field.
    actual_param=$(echo "${cert_text}" | grep -F "ASN1 OID:" | head -1 | xargs) || true
    if [[ -z "${actual_param}" ]]; then
      actual_param=$(echo "${cert_text}" | grep -F "Public-Key:" | head -1 | xargs) || true
    fi
    echo "  FAIL: Expected '${expected_param_str}', got '${actual_param:-not found}'" | tee -a "${ARTIFACT_LOG}"
    status="FAIL"
  fi

  if [[ "${status}" == "FAIL" ]]; then
    failures=$((failures + 1))
  fi
  results+=("${status}|${description}|${namespace}/${secret_name}")
done

# Verify PKI CR
echo ""
echo "--- Checking PKI CR ---" | tee -a "${ARTIFACT_LOG}"
total=$((total + 1))

pki_cr=$(oc get pki cluster -o yaml 2>&1) || true

if [[ -z "${pki_cr}" ]] || echo "${pki_cr}" | grep -q "not found\|error\|Error"; then
  echo "  FAIL: PKI CR 'cluster' not found or error retrieving it" | tee -a "${ARTIFACT_LOG}"
  echo "${pki_cr}" >> "${ARTIFACT_LOG}"
  results+=("FAIL|PKI CR|not found or error")
  failures=$((failures + 1))
else
  echo "${pki_cr}" >> "${ARTIFACT_LOG}"
  pki_status="PASS"

  # Check mode
  mode=$(echo "${pki_cr}" | grep "mode:" | head -1 | awk '{print $2}' || true)
  if [[ "${mode}" == "${EXPECTED_PKI_MODE}" ]]; then
    echo "  Mode: ${EXPECTED_PKI_MODE} - OK"
  else
    echo "  FAIL: Expected mode '${EXPECTED_PKI_MODE}', got '${mode:-not set}'" | tee -a "${ARTIFACT_LOG}"
    pki_status="FAIL"
  fi

  if [[ "${pki_status}" == "FAIL" ]]; then
    failures=$((failures + 1))
  fi
  results+=("${pki_status}|PKI CR|mode=${mode:-unknown}")
fi

# Print summary table
echo ""
echo "============================================="
echo "PKI Verification Summary"
echo "============================================="
printf "%-6s | %-45s | %s\n" "STATUS" "CHECK" "DETAIL"
printf "%-6s-+-%-45s-+-%s\n" "------" "---------------------------------------------" "------"
for result in "${results[@]}"; do
  IFS='|' read -r rstatus rdesc rdetail <<< "${result}"
  printf "%-6s | %-45s | %s\n" "${rstatus}" "${rdesc}" "${rdetail}"
done
echo ""
echo "Total: ${total}, Passed: $((total - failures)), Failed: ${failures}"
echo "============================================="

if [[ ${failures} -gt 0 ]]; then
  echo ""
  echo "FAILURE: ${failures} check(s) failed. See ${ARTIFACT_LOG} for details."
  exit 1
fi

echo ""
echo "All PKI checks passed."
