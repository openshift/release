#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

# CNTRLPLANE-2914: Testing controlPlaneVersion status field
# Runs TestUpgradeControlPlane then verifies controlPlaneVersion on the resulting clusters.

function cleanup() {
  for child in $( jobs -p ); do
    kill "${child}"
  done
  wait
}
trap cleanup EXIT

check_e2e_flag() {
  grep -q "$1" <<<"$( bin/test-e2e -h 2>&1 )"
  return $?
}

# Set up test parameters
REQUEST_SERVING_COMPONENT_TEST="${REQUEST_SERVING_COMPONENT_TEST:-}"
REQUEST_SERVING_COMPONENT_PARAMS=""

if [[ "${REQUEST_SERVING_COMPONENT_TEST:-}" == "true" ]]; then
   REQUEST_SERVING_COMPONENT_PARAMS="--e2e.test-request-serving-isolation \
  --e2e.management-parent-kubeconfig=${MGMT_PARENT_KUBECONFIG} \
  --e2e.management-cluster-namespace=$(cat "${SHARED_DIR}/management_cluster_namespace") \
  --e2e.management-cluster-name=$(cat "${SHARED_DIR}/management_cluster_name")"
fi

PKI_RECONCILIATION_PARAMS=""
if [[ "${DISABLE_PKI_RECONCILIATION:-}" == "true" ]]; then
  PKI_RECONCILIATION_PARAMS="--e2e.disable-pki-reconciliation=true"
fi

AWS_OBJECT_PARAMS=""
if check_e2e_flag 'e2e.aws-oidc-s3-bucket-name'; then
  AWS_OBJECT_PARAMS="--e2e.aws-oidc-s3-bucket-name=hypershift-ci-oidc --e2e.aws-kms-key-alias=alias/hypershift-ci"
fi

AWS_MULTI_ARCH_PARAMS=""
if [[ "${AWS_MULTI_ARCH:-}" == "true" ]]; then
  AWS_MULTI_ARCH_PARAMS="--e2e.aws-multi-arch=true"
fi

N1_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N1} != "${OCP_IMAGE_LATEST}" ]]; then
  N1_NP_VERSION_TEST_ARGS="--e2e.n1-minor-release-image=${OCP_IMAGE_N1}"
fi

N2_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N2} != "${OCP_IMAGE_LATEST}" ]]; then
  N2_NP_VERSION_TEST_ARGS="--e2e.n2-minor-release-image=${OCP_IMAGE_N2}"
fi

N3_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N3} != "${OCP_IMAGE_LATEST}" ]]; then
  N3_NP_VERSION_TEST_ARGS="--e2e.n3-minor-release-image=${OCP_IMAGE_N3}"
fi

N4_NP_VERSION_TEST_ARGS=""
if [[ ${OCP_IMAGE_N4} != "${OCP_IMAGE_LATEST}" ]]; then
  N4_NP_VERSION_TEST_ARGS="--e2e.n4-minor-release-image=${OCP_IMAGE_N4}"
fi

# CNTRLPLANE-2914: hardcoded control plane operator image
CONTROL_PLANE_OPERATOR_IMAGE_PARAM="--e2e.control-plane-operator-image=quay.io/wangke19/hypershift:CNTRLPLANE-2914-control-plane"

export EVENTUALLY_VERBOSE="false"

# Run the e2e test
hack/ci-test-e2e.sh -test.v \
  -test.run="${CI_TESTS_RUN:-}" \
  -test.parallel=20 \
  --e2e.aws-credentials-file=/etc/hypershift-pool-aws-credentials/credentials \
  --e2e.aws-zones=us-east-1a,us-east-1b,us-east-1c \
  ${AWS_OBJECT_PARAMS:-} \
  --e2e.pull-secret-file=/etc/ci-pull-credentials/.dockerconfigjson \
  --e2e.base-domain=ci.hypershift.devcluster.openshift.com \
  --e2e.latest-release-image="${OCP_IMAGE_LATEST}" \
  --e2e.previous-release-image="${OCP_IMAGE_PREVIOUS}" \
  ${PKI_RECONCILIATION_PARAMS:-} \
  ${N1_NP_VERSION_TEST_ARGS:-} \
  ${N2_NP_VERSION_TEST_ARGS:-} \
  ${N3_NP_VERSION_TEST_ARGS:-} \
  ${N4_NP_VERSION_TEST_ARGS:-} \
  --e2e.additional-tags="expirationDate=$(date -d '4 hours' --iso=minutes --utc)" \
  --e2e.aws-endpoint-access=PublicAndPrivate \
  --e2e.external-dns-domain=service.ci.hypershift.devcluster.openshift.com \
  ${AWS_MULTI_ARCH_PARAMS:-} \
  ${REQUEST_SERVING_COMPONENT_PARAMS:-} \
  ${CONTROL_PLANE_OPERATOR_IMAGE_PARAM:-} &

E2E_PID=$!

# Dynamic wait: poll every 60s and print progress until the e2e process finishes
echo "Waiting for e2e (PID=${E2E_PID}) to complete..."
while kill -0 "${E2E_PID}" 2>/dev/null; do
  echo "[$(date -u '+%H:%M:%S')] e2e still running (PID=${E2E_PID})..."
  sleep 60
done
wait "${E2E_PID}"
E2E_EXIT_CODE=$?
echo "[$(date -u '+%H:%M:%S')] e2e finished with exit code ${E2E_EXIT_CODE}"

# Save raw verbose test output so it appears as an artifact in the Prow job
if [[ -f /tmp/test_out ]]; then
  cp /tmp/test_out "${ARTIFACT_DIR}/e2e-test-output.log"
  echo "Saved raw test log to ${ARTIFACT_DIR}/e2e-test-output.log"
fi

# Record detailed test results from JUnit XML produced by hack/ci-test-e2e.sh
echo ""
echo "=========================================="
echo "CNTRLPLANE-2914: E2E Test Report"
echo "=========================================="
JUNIT_FILE="${ARTIFACT_DIR}/junit.xml"
if [[ -f "${JUNIT_FILE}" ]]; then
  total=$(python3 -c "
import xml.etree.ElementTree as ET, sys
tree = ET.parse('${JUNIT_FILE}')
root = tree.getroot()
suite = root if root.tag == 'testsuite' else root.find('testsuite')
tests    = int(suite.get('tests', 0))
failures = int(suite.get('failures', 0))
errors   = int(suite.get('errors', 0))
skipped  = int(suite.get('skipped', 0))
passed   = tests - failures - errors - skipped
print(f'Total={tests} Passed={passed} Failed={failures} Errors={errors} Skipped={skipped}')
" 2>/dev/null || echo "parse error")
  echo "Summary: ${total}"

  echo ""
  echo "--- Failed tests ---"
  python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('${JUNIT_FILE}')
root = tree.getroot()
suite = root if root.tag == 'testsuite' else root.find('testsuite')
failed = [tc for tc in suite.findall('testcase') if tc.find('failure') is not None or tc.find('error') is not None]
if not failed:
    print('  (none)')
for tc in failed:
    name = tc.get('name', '?')
    msg_el = tc.find('failure') or tc.find('error')
    msg = (msg_el.get('message') or msg_el.text or '').strip().splitlines()[0][:200]
    print(f'  ✗ {name}')
    print(f'    {msg}')
" 2>/dev/null || echo "  (could not parse junit.xml)"
else
  echo "junit.xml not found at ${JUNIT_FILE}"
fi

# ------------------------------------------------------------------
# CNTRLPLANE-2914: Post-test verification of controlPlaneVersion field
# Covers TEST-1 through TEST-6 in TEST_PLAN.md
# ------------------------------------------------------------------
echo ""
echo "=========================================="
echo "CNTRLPLANE-2914: Post-test verification"
echo "=========================================="

# Use 3 hours to cover the full TestUpgradeControlPlane duration
SINCE_TIME="$(date -u -d '3 hours ago' --iso-8601=seconds)"
oc get hostedclusters --all-namespaces -o json \
  | jq -r --arg since "${SINCE_TIME}" \
      '.items[] | select(.metadata.creationTimestamp > $since) | "\(.metadata.namespace)/\(.metadata.name)"' \
  > /tmp/test-clusters.txt || true

if [[ ! -s /tmp/test-clusters.txt ]]; then
  echo "No HostedClusters found from this test run — skipping verification"
  exit "${E2E_EXIT_CODE}"
fi

VERIFY_FAIL=0

while IFS= read -r cluster; do
  namespace="${cluster%%/*}"
  name="${cluster##*/}"
  hcp_namespace="${namespace}-${name}"

  echo ""
  echo "=========================================="
  echo "Cluster: ${namespace}/${name}"
  echo "=========================================="

  # ----------------------------------------------------------------
  # TEST-1: controlPlaneVersion present on HC and HCP, values match
  # ----------------------------------------------------------------
  echo ""
  echo "--- TEST-1: Field presence on HC and HCP ---"

  hc_cp_json=$(oc get hc "$name" -n "$namespace" -o jsonpath='{.status.controlPlaneVersion}' 2>/dev/null || true)
  if [[ -z "${hc_cp_json}" ]] || [[ "${hc_cp_json}" == "null" ]]; then
    echo "✗ FAIL TEST-1: HC controlPlaneVersion field missing or null"
    VERIFY_FAIL=1
  else
    echo "✓ PASS: HC controlPlaneVersion present"

    hcp_name=$(oc get hostedcontrolplane -n "$hcp_namespace" --no-headers -o name 2>/dev/null \
               | head -1 | sed 's|hostedcontrolplane.hypershift.openshift.io/||')
    if [[ -z "${hcp_name}" ]]; then
      echo "✗ FAIL TEST-1: HostedControlPlane not found in ${hcp_namespace}"
      VERIFY_FAIL=1
    else
      hcp_cp_json=$(oc get hostedcontrolplane "$hcp_name" -n "$hcp_namespace" \
                    -o jsonpath='{.status.controlPlaneVersion}' 2>/dev/null || true)
      if [[ -z "${hcp_cp_json}" ]] || [[ "${hcp_cp_json}" == "null" ]]; then
        echo "✗ FAIL TEST-1: HCP controlPlaneVersion field missing or null"
        VERIFY_FAIL=1
      else
        echo "✓ PASS: HCP controlPlaneVersion present"

        hc_ver=$(oc get hc "$name" -n "$namespace" \
                  -o jsonpath='{.status.controlPlaneVersion.desired.version}')
        hcp_ver=$(oc get hostedcontrolplane "$hcp_name" -n "$hcp_namespace" \
                   -o jsonpath='{.status.controlPlaneVersion.desired.version}')
        hc_img=$(oc get hc "$name" -n "$namespace" \
                  -o jsonpath='{.status.controlPlaneVersion.desired.image}')
        hcp_img=$(oc get hostedcontrolplane "$hcp_name" -n "$hcp_namespace" \
                   -o jsonpath='{.status.controlPlaneVersion.desired.image}')

        echo "HC  desired.version: ${hc_ver}"
        echo "HCP desired.version: ${hcp_ver}"
        if [[ "${hc_ver}" == "${hcp_ver}" ]] && [[ "${hc_img}" == "${hcp_img}" ]]; then
          echo "✓ PASS TEST-1: HC and HCP controlPlaneVersion.desired match"
        else
          echo "✗ FAIL TEST-1: HC/HCP desired version or image mismatch"
          echo "  HC  image: ${hc_img}"
          echo "  HCP image: ${hcp_img}"
          VERIFY_FAIL=1
        fi

        # ----------------------------------------------------------------
        # TEST-7: WaitForControlPlaneRollout check — image match AND state
        # isControlPlaneVersionCompleted checks desired.image == history[0].image
        # ----------------------------------------------------------------
        echo ""
        echo "--- TEST-7: WaitForControlPlaneRollout image+state check ---"
        h0_img=$(oc get hc "$name" -n "$namespace" \
                  -o jsonpath='{.status.controlPlaneVersion.history[0].image}' 2>/dev/null || true)
        h0_state=$(oc get hc "$name" -n "$namespace" \
                    -o jsonpath='{.status.controlPlaneVersion.history[0].state}' 2>/dev/null || true)
        echo "desired.image:         ${hc_img}"
        echo "history[0].image:      ${h0_img}"
        echo "history[0].state:      ${h0_state}"
        if [[ "${hc_img}" == "${h0_img}" ]] && [[ "${h0_state}" == "Completed" ]]; then
          echo "✓ PASS TEST-7: desired.image matches history[0].image and state=Completed"
        elif [[ "${hc_img}" != "${h0_img}" ]]; then
          echo "✗ FAIL TEST-7: desired.image does not match history[0].image"
          VERIFY_FAIL=1
        else
          echo "✗ FAIL TEST-7: history[0].state=${h0_state} (expected Completed)"
          VERIFY_FAIL=1
        fi
      fi
    fi
  fi

  # ----------------------------------------------------------------
  # TEST-2: Full field structure validation
  # NOTE: CompletionTime is metav1.Time with omitzero — it is ABSENT from JSON
  # (not "null") when the entry is Partial. Use has("completionTime") to check.
  # ----------------------------------------------------------------
  echo ""
  echo "--- TEST-2: Field structure ---"
  cp_state=$(oc get hc "$name" -n "$namespace" \
              -o jsonpath='{.status.controlPlaneVersion.history[0].state}' 2>/dev/null || true)

  oc get hc "$name" -n "$namespace" -o jsonpath='{.status.controlPlaneVersion}' | jq '{
    desired_version_set:         (.desired.version | length > 0),
    desired_image_set:           (.desired.image | length > 0),
    history_count:               (.history | length),
    history_count_at_least_1:   ((.history | length) >= 1),
    history_state:               .history[0].state,
    history_version_set:         (.history[0].version | length > 0),
    history_image_set:           (.history[0].image | length > 0),
    history_startedTime_set:     (.history[0].startedTime | length > 0),
    history_completionTime_set:  (.history[0] | has("completionTime")),
    observedGeneration_nonzero:  (.observedGeneration > 0)
  }' || true

  if [[ "${cp_state}" == "Completed" ]]; then
    echo "✓ PASS TEST-2: history[0].state=Completed, structure valid"

    # When Completed, completionTime must be present (not absent/zero)
    ct=$(oc get hc "$name" -n "$namespace" \
          -o jsonpath='{.status.controlPlaneVersion.history[0].completionTime}' 2>/dev/null || true)
    if [[ -n "${ct}" ]]; then
      echo "✓ PASS TEST-2: completionTime present when Completed (${ct})"
    else
      echo "✗ FAIL TEST-2: completionTime absent for Completed entry"
      VERIFY_FAIL=1
    fi
  else
    echo "✗ FAIL TEST-2: history[0].state=${cp_state} (expected Completed)"
    VERIFY_FAIL=1

    # When Partial, completionTime must be ABSENT from JSON (omitzero, not null)
    ct_raw=$(oc get hc "$name" -n "$namespace" \
              -o jsonpath='{.status.controlPlaneVersion.history[0]}' 2>/dev/null \
              | jq 'has("completionTime")' || echo "false")
    if [[ "${ct_raw}" == "false" ]]; then
      echo "✓ PASS TEST-2: completionTime correctly absent (omitzero) in Partial state"
    else
      echo "✗ FAIL TEST-2: completionTime present in Partial state (should be omitted)"
      VERIFY_FAIL=1
    fi
  fi

  # pruneHistory() cap: history must never exceed 100 entries (MaxItems=100)
  # history must have at least 1 entry once populated (MinItems=1)
  history_len=$(oc get hc "$name" -n "$namespace" \
                 -o jsonpath='{.status.controlPlaneVersion.history}' 2>/dev/null \
                 | jq 'length' || echo "0")
  echo "History length: ${history_len}"
  if [[ "${history_len}" -ge 1 ]] && [[ "${history_len}" -le 100 ]]; then
    echo "✓ PASS TEST-2: history length ${history_len} in [1, 100] (MinItems/MaxItems enforced)"
  elif [[ "${history_len}" -eq 0 ]]; then
    echo "✗ FAIL TEST-2: history is empty (MinItems=1 violated)"
    VERIFY_FAIL=1
  else
    echo "✗ FAIL TEST-2: history length ${history_len} exceeds 100 (pruneHistory not working)"
    VERIFY_FAIL=1
  fi

  # ----------------------------------------------------------------
  # TEST-3: controlPlaneVersion completes before version
  # ----------------------------------------------------------------
  echo ""
  echo "--- TEST-3: controlPlaneVersion completes before version ---"
  cp_completion=$(oc get hc "$name" -n "$namespace" \
                   -o jsonpath='{.status.controlPlaneVersion.history[0].completionTime}' 2>/dev/null || true)
  ver_completion=$(oc get hc "$name" -n "$namespace" \
                    -o jsonpath='{.status.version.history[0].completionTime}' 2>/dev/null || true)
  ver_state=$(oc get hc "$name" -n "$namespace" \
               -o jsonpath='{.status.version.history[0].state}' 2>/dev/null || true)
  echo "controlPlaneVersion completionTime: ${cp_completion}"
  echo "version           completionTime: ${ver_completion}"
  echo "version           state:          ${ver_state}"

  if [[ -n "${cp_completion}" ]] && [[ -n "${ver_completion}" ]]; then
    if [[ "${cp_completion}" < "${ver_completion}" ]] || [[ "${cp_completion}" == "${ver_completion}" ]]; then
      echo "✓ PASS TEST-3: controlPlaneVersion completed before or same time as version"
    else
      echo "✗ FAIL TEST-3: controlPlaneVersion completed AFTER version"
      VERIFY_FAIL=1
    fi
  elif [[ -n "${cp_completion}" ]] && [[ -z "${ver_completion}" ]]; then
    echo "✓ PASS TEST-3: controlPlaneVersion=Completed, version still Partial (expected for zero-NodePool)"
  else
    echo "⚠ INFO TEST-3: controlPlaneVersion not yet completed (cp=${cp_completion})"
  fi

  # ----------------------------------------------------------------
  # TEST-4: ControlPlaneComponent aggregation
  # ----------------------------------------------------------------
  echo ""
  echo "--- TEST-4: ControlPlaneComponent aggregation ---"
  desired_version=$(oc get hc "$name" -n "$namespace" \
                     -o jsonpath='{.status.controlPlaneVersion.desired.version}' 2>/dev/null || true)
  total_components=$(oc get controlplanecomponent -n "$hcp_namespace" --no-headers 2>/dev/null | wc -l || echo "0")
  echo "ControlPlaneComponent count: ${total_components}"
  echo "Desired version: ${desired_version}"

  if [[ "${total_components}" -gt 0 ]]; then
    at_version=$(oc get controlplanecomponent -n "$hcp_namespace" -o json 2>/dev/null \
      | jq --arg v "${desired_version}" \
          '[.items[] | select(.status.version == $v) |
            select((.status.conditions // []) | map(select(.type=="RolloutComplete") | select(.status=="True")) | length > 0)
          ] | length' || echo "0")
    echo "At desired version with RolloutComplete=True: ${at_version}/${total_components}"

    oc get controlplanecomponent -n "$hcp_namespace" -o json 2>/dev/null \
      | jq -r --arg v "${desired_version}" \
          '.items[] | "\(.metadata.name): version=\(.status.version // "N/A"), RolloutComplete=\(
            (.status.conditions // []) | map(select(.type=="RolloutComplete")) | .[0].status // "N/A"
          )"' || true

    if [[ "${at_version}" == "${total_components}" ]]; then
      if [[ "${cp_state}" == "Completed" ]]; then
        echo "✓ PASS TEST-4: all ${total_components} components ready, state=Completed"
      else
        echo "✗ FAIL TEST-4: all components ready but state=${cp_state}"
        VERIFY_FAIL=1
      fi
    else
      echo "⚠ INFO TEST-4: ${at_version}/${total_components} components ready, state=${cp_state}"
    fi
  else
    echo "⚠ INFO TEST-4: no ControlPlaneComponent resources found"
  fi

  # ----------------------------------------------------------------
  # TEST-5: observedGeneration tracks HCP generation
  # ----------------------------------------------------------------
  echo ""
  echo "--- TEST-5: observedGeneration vs HCP generation ---"
  hcp_name=$(oc get hostedcontrolplane -n "$hcp_namespace" --no-headers -o name 2>/dev/null \
             | head -1 | sed 's|hostedcontrolplane.hypershift.openshift.io/||')
  if [[ -n "${hcp_name}" ]]; then
    hcp_gen=$(oc get hostedcontrolplane "$hcp_name" -n "$hcp_namespace" \
               -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
    obs_gen=$(oc get hostedcontrolplane "$hcp_name" -n "$hcp_namespace" \
               -o jsonpath='{.status.controlPlaneVersion.observedGeneration}' 2>/dev/null || true)
    echo "HCP metadata.generation:                           ${hcp_gen}"
    echo "HCP status.controlPlaneVersion.observedGeneration: ${obs_gen}"
    if [[ "${hcp_gen}" == "${obs_gen}" ]]; then
      echo "✓ PASS TEST-5: observedGeneration matches HCP generation"
    else
      echo "⚠ INFO TEST-5: observedGeneration=${obs_gen} != HCP generation=${hcp_gen}"
      echo "  Check CPO logs — may indicate error path (ensureControlPlaneVersionPartial) ran"
    fi
  else
    echo "⚠ INFO TEST-5: HostedControlPlane not found, skipping"
  fi

  # ----------------------------------------------------------------
  # TEST-6: Backward compatibility — existing fields still present
  # ----------------------------------------------------------------
  echo ""
  echo "--- TEST-6: Backward compatibility ---"
  oc get hc "$name" -n "$namespace" -o json | jq '{
    version_present:             (.status.version != null),
    version_history_nonempty:    (.status.version.history | length > 0),
    controlPlaneVersion_present: (.status.controlPlaneVersion != null)
  }' || true

  ver_present=$(oc get hc "$name" -n "$namespace" \
                 -o jsonpath='{.status.version.desired.version}' 2>/dev/null || true)
  if [[ -n "${ver_present}" ]]; then
    echo "✓ PASS TEST-6: existing version field still populated (${ver_present})"
  else
    echo "✗ FAIL TEST-6: existing version field is empty — possible regression"
    VERIFY_FAIL=1
  fi

  echo ""
  echo "--- Full controlPlaneVersion / version comparison ---"
  oc get hc "$name" -n "$namespace" -o json | jq '{
    controlPlaneVersion: .status.controlPlaneVersion,
    version: {desired: .status.version.desired, history_0: .status.version.history[0]},
    hc_generation: .metadata.generation
  }' || true

done < /tmp/test-clusters.txt

echo ""
echo "=========================================="
echo "CNTRLPLANE-2914: Verification complete"
echo "E2E exit code:    ${E2E_EXIT_CODE}"
if [[ "${VERIFY_FAIL}" -ne 0 ]]; then
  echo "Verification:     FAIL (see ✗ lines above)"
else
  echo "Verification:     PASS"
fi
echo "=========================================="

# Fail if either the e2e test or the verification failed
if [[ "${E2E_EXIT_CODE}" -ne 0 ]]; then
  exit "${E2E_EXIT_CODE}"
fi
exit "${VERIFY_FAIL}"
