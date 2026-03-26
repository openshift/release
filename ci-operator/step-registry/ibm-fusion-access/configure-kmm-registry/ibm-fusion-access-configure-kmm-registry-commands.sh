#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

# Purpose: Ensure namespaces exist and create kmm-image-config ConfigMaps for the Fusion Access and Storage Scale operator namespaces so KMM uses the expected registry.
# Inputs: FA__NAMESPACE, FA__SCALE__OPERATOR_NAMESPACE, FA__KMM__REGISTRY_*, MAP_TESTS, REPORTPORTAL_CMP (step ref env); ARTIFACT_DIR (CI).
# Non-obvious: JUnit subtests record namespace readiness and configmap apply; xtrace is disabled around literals that may contain registry credentials.

typeset junitResultsFile="${ARTIFACT_DIR}/junit_configure_kmm_registry_tests.xml"
typeset -i testStartTime="${SECONDS}"
typeset -i testsTotal=0
typeset -i testsFailed=0
typeset testCases=''

function AddTestResult () {
  typeset testName="${1}"; (($#)) && shift
  typeset testStatus="${1}"; (($#)) && shift
  typeset testDuration="${1}"; (($#)) && shift
  typeset testMessage="${1:-}"; (($#)) && shift
  typeset testClassName="${1:-ConfigureKMMRegistryTests}"; (($#)) && shift

  testsTotal=$((testsTotal + 1))

  if [[ "${testStatus}" == "passed" ]]; then
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\"/>"
  else
    testsFailed=$((testsFailed + 1))
    testCases="${testCases}
    <testcase name=\"${testName}\" classname=\"${testClassName}\" time=\"${testDuration}\">
      <failure message=\"Test failed\">${testMessage}</failure>
    </testcase>"
  fi

  true
}

function InstallYQIfNotExists () {
  if ! command -v yq >/dev/null; then
    mkdir -p /tmp/bin
    export PATH="${PATH}:/tmp/bin"
    curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
      -o /tmp/bin/yq && chmod +x /tmp/bin/yq
  fi

  true
}

function MapTestsForComponentReadiness () {
  [[ "${MAP_TESTS}" != "true" ]] && return

  typeset resultsFile="${1}"; (($#)) && shift
  if [[ -f "${resultsFile}" ]]; then
    InstallYQIfNotExists
    yq eval -px -ox -iI0 '.testsuites.testsuite.+@name=env(REPORTPORTAL_CMP)' "${resultsFile}"
  fi

  true
}

function GenerateJunitXml () {
  typeset -i totalDuration=$((SECONDS - testStartTime))

  cat > "${junitResultsFile}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="Configure KMM Registry Tests" tests="${testsTotal}" failures="${testsFailed}" errors="0" time="${totalDuration}">
${testCases}
  </testsuite>
</testsuites>
EOF

  MapTestsForComponentReadiness "${JUNIT_RESULTS_FILE:-${junitResultsFile}}"

  if [[ -n "${SHARED_DIR}" ]] && [[ -d "${SHARED_DIR}" ]]; then
    cp "${junitResultsFile}" "${SHARED_DIR}/$(basename "${junitResultsFile}")"
  fi

  if [[ "${testsFailed}" -gt 0 ]]; then
    exit 1
  fi

  true
}

trap '{( GenerateJunitXml; true )}' EXIT

typeset fullRepo="${FA__KMM__REGISTRY_ORG}/${FA__KMM__REGISTRY_REPO}"

typeset -i td="${SECONDS}"
typeset ts='failed'
typeset msg=''
if oc create namespace "${FA__NAMESPACE}" --dry-run=client -o json --save-config | oc apply -f - \
  && oc wait --for=create "Namespace/${FA__NAMESPACE}" --timeout=60s; then
  ts='passed'
else
  oc get namespace "${FA__NAMESPACE}" -o yaml --ignore-not-found
  msg='Failed to ensure Fusion Access namespace exists and is ready'
fi
td=$((SECONDS - td))
AddTestResult "test_kmm_namespace_ready" "${ts}" "${td}" "${msg}"

td="${SECONDS}"
ts='failed'
msg=''
set +x
if oc create configmap kmm-image-config \
  -n "${FA__NAMESPACE}" \
  --from-literal=kmm_image_registry_url="${FA__KMM__REGISTRY_URL}" \
  --from-literal=kmm_image_repo="${fullRepo}" \
  --from-literal=kmm_tls_insecure="false" \
  --from-literal=kmm_tls_skip_verify="false" \
  --dry-run=client -o json --save-config | oc apply -f -; then
  ts='passed'
else
  msg='Failed to apply kmm-image-config in Fusion Access namespace'
fi
set -x
td=$((SECONDS - td))
AddTestResult "test_kmm_configmap_fusion_access_namespace" "${ts}" "${td}" "${msg}"

td="${SECONDS}"
ts='failed'
msg=''
set +x
if oc create configmap kmm-image-config \
  -n "${FA__SCALE__OPERATOR_NAMESPACE}" \
  --from-literal=kmm_image_registry_url="${FA__KMM__REGISTRY_URL}" \
  --from-literal=kmm_image_repo="${fullRepo}" \
  --from-literal=kmm_tls_insecure="false" \
  --from-literal=kmm_tls_skip_verify="false" \
  --dry-run=client -o json --save-config | oc apply -f -; then
  ts='passed'
else
  msg='Failed to apply kmm-image-config in IBM Storage Scale operator namespace'
fi
set -x
td=$((SECONDS - td))
AddTestResult "test_kmm_configmap_scale_operator_namespace" "${ts}" "${td}" "${msg}"

true
