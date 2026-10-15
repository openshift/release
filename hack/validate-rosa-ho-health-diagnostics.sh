#!/bin/bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STEP_ROOT="${REPO_ROOT}/ci-operator/step-registry/rosa/hypershift-operator"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT
mkdir -p "${TEST_ROOT}/bin"
export PATH="${TEST_ROOT}/bin:${PATH}"
export CLUSTER_SECTOR=test REGION=test OCM_LOGIN_ENV=test
export SHARED_DIR="${TEST_ROOT}/shared" CLUSTER_PROFILE_DIR="${TEST_ROOT}/profile"
export ARTIFACT_DIR="${TEST_ROOT}/artifacts" CALLS="${TEST_ROOT}/calls"
export FIXTURE="${TEST_ROOT}/fixture.json" MODE=upgrade
mkdir -p "${SHARED_DIR}" "${CLUSTER_PROFILE_DIR}"
printf 'mock-only' > "${CLUSTER_PROFILE_DIR}/ocm-token"
printf 'mock-only' > "${SHARED_DIR}/hs-mc.kubeconfig"
jq -n '{items: [{apiVersion: "hypershift.openshift.io/v1beta1", kind: "NodePool",
  metadata: {name: "test-pool", namespace: "test-tenant", generation: 7,
    annotations: {excluded: "do-not-retain"}}, spec: {excluded: "do-not-retain"},
  status: {excluded: "do-not-retain", conditions: [{type: "Ready", status: "False",
    reason: "MachineError", message: (("full machine error; " * 100) + "END-OF-ERROR"),
    lastTransitionTime: "2026-01-01T00:00:00Z", observedGeneration: 7}]}}]}' > "${FIXTURE}"

cat > "${TEST_ROOT}/bin/mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
tool=${0##*/}
printf '%s %s\n' "${tool}" "$*" >> "${CALLS}"
diagnostic=false
if [[ "${tool}" == oc && "${*: -1}" == --request-timeout=15s ]]; then
  diagnostic=true
  set -- "${@:1:$#-1}"
fi
case "${tool}" in
  sleep) [[ "$*" == 120 ]] ;;
  curl) printf '{"tags":[{"name":"latest-test","manifest_digest":"sha256:test"}]}' ;;
  ocm)
    case "$*" in
      login*) ;;
      *management_clusters*) printf '{"items":[{"cluster_management_reference":{"cluster_id":"test-mc"}}]}' ;;
      *credentials*) printf '{"kubeconfig":"mock-only"}' ;;
      *) printf '{"name":"test-mc"}' ;;
    esac ;;
  oc)
    case "$*" in
      'get configmap'*) if [[ "${MODE}" == locked ]]; then echo test-job; fi ;;
      'get deployment'*image*)
        if [[ "${MODE}" == match ]]; then
          echo quay.io/acm-d/rhtap-hypershift-operator@sha256:test
        else
          echo previous-image
        fi ;;
      'get deployment'*readyReplicas*)
        if [[ "${MODE}" == early-failure ]]; then exit 23; fi
        echo 1 ;;
      'set image'*) if [[ "${MODE}" == mutation-failure ]]; then exit 24; fi ;;
      'rollout status'*) [[ "${MODE}" != rollout-failure ]] ;;
      'get hostedclusters -A --no-headers'|'get nodepools -A --no-headers') echo test-resource ;;
      'get hostedclusters -A -o wide'|'get nodepools -A -o wide') echo truncated-display ;;
      'get hostedclusters -A -o json'|'get nodepools -A -o json')
        if ${diagnostic} && [[ "${MODE}" == diagnostics-failure || "${MODE}" == diagnostics-pass || "${MODE}" == baseline-failure ]]; then
          echo 'mock diagnostic request timeout' >&2
          exit 42
        fi
        if ${diagnostic} && [[ "${MODE}" == malformed ]]; then echo '{invalid'; exit 0; fi
        if [[ "${MODE}" == healthy || "${MODE}" == diagnostics-pass ]]; then
          jq '.items[].status.conditions[].status = "True"' "${FIXTURE}"
        else
          cat "${FIXTURE}"
        fi ;;
      'get pods -n hypershift -o json') echo '{"items":[]}' ;;
      *) echo "Unexpected mock invocation: $*" >&2; exit 90 ;;
    esac ;;
  *) exit 91 ;;
esac
MOCK
chmod +x "${TEST_ROOT}/bin/mock"
for tool in oc ocm curl sleep; do ln -s mock "${TEST_ROOT}/bin/${tool}"; done

run_step() {
  local step="${1}" mode="${2}" expected="${3}" actual=0
  export MODE="${mode}"
  rm -rf "${ARTIFACT_DIR}"
  if [[ "${mode}" == artifact-unavailable ]]; then
    printf 'not a directory' > "${ARTIFACT_DIR}"
  fi
  : > "${CALLS}"
  bash "${STEP_ROOT}/${step}/rosa-hypershift-operator-${step}-commands.sh" > "${TEST_ROOT}/output" 2>&1 || actual=$?
  if [[ "${actual}" != "${expected}" ]]; then
    cat "${TEST_ROOT}/output"
    echo "FAIL: ${step}/${mode}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

check_snapshot() {
  local phase="${1}" resource
  for resource in hostedclusters nodepools; do
    jq -e --arg phase "${phase}" --slurpfile source "${FIXTURE}" '
      .phase == $phase and (.capturedAt | test("^[0-9-]+T[0-9:]+Z$")) and
      .items[0].metadata == {name: "test-pool", namespace: "test-tenant", generation: 7} and
      .items[0].conditions == $source[0].items[0].status.conditions and
      (.items[0] | keys == ["apiVersion", "conditions", "kind", "metadata"])
    ' "${ARTIFACT_DIR}/ho-health/${phase}-${resource}.json" > /dev/null
  done
  if grep -Rq 'do-not-retain' "${ARTIFACT_DIR}"; then exit 1; fi
}

run_step deploy upgrade 0
check_snapshot before-deploy
check_snapshot after-deploy
baseline_line=$(grep -n '^oc get nodepools -A -o json --request-timeout=15s$' "${CALLS}" | head -1 | cut -d: -f1)
mutation_line=$(grep -n '^oc set image ' "${CALLS}" | cut -d: -f1)
[[ "${baseline_line}" -lt "${mutation_line}" ]]
echo 'PASS: baseline precedes mutation; full conditions retained; non-health fields excluded'

for mode in match locked; do
  run_step deploy "${mode}" 0
  check_snapshot before-deploy
  check_snapshot after-deploy
  if grep -q '^oc set image ' "${CALLS}"; then
    echo 'FAIL: skipped deploy mutated image' >&2
    exit 1
  fi
done
echo 'PASS: baseline retained when image already matches or deployment is locked'

run_step deploy rollout-failure 1
check_snapshot before-deploy
check_snapshot after-deploy
echo 'PASS: deployment failure retains both snapshots and failure status'

run_step deploy mutation-failure 24
check_snapshot before-deploy
check_snapshot after-deploy
echo 'PASS: mutation failure preserves exact exit code and snapshots'

for mode in baseline-failure malformed; do
  run_step deploy "${mode}" 0
  grep -q '^oc set image ' "${CALLS}"
  grep -q 'WARN: Cannot collect before-deploy' "${TEST_ROOT}/output"
  [[ -z "$(find "${ARTIFACT_DIR}" -type f -print -quit)" ]]
done
echo 'PASS: baseline timeout or malformed data is explicit and does not block deploy'

run_step verify-hcp-health not-ready 1
check_snapshot after-verification
grep -q 'NodePools are not ready' "${TEST_ROOT}/output"
echo 'PASS: failed verification retains complete condition errors'

run_step verify-hcp-health early-failure 23
check_snapshot after-verification
echo 'PASS: early errexit retains artifacts and original exit code'

run_step verify-hcp-health artifact-unavailable 1
grep -q 'RESULT: FAILED' "${TEST_ROOT}/output"
grep -q 'WARN: Cannot create after-verification' "${TEST_ROOT}/output"
echo 'PASS: unavailable artifact directory cannot mask readiness failure'

run_step verify-hcp-health diagnostics-failure 1
grep -q 'RESULT: FAILED' "${TEST_ROOT}/output"
grep -q 'WARN: Cannot collect after-verification hostedclusters' "${TEST_ROOT}/output"
grep -q 'WARN: Cannot collect after-verification nodepools' "${TEST_ROOT}/output"
[[ -z "$(find "${ARTIFACT_DIR}" -type f -print -quit)" ]]
echo 'PASS: diagnostic failures are explicit and cannot mask readiness failure'

run_step verify-hcp-health diagnostics-pass 0
grep -q 'WARN: Cannot collect' "${TEST_ROOT}/output"
echo 'PASS: diagnostic failure does not alter readiness success'

run_step verify-hcp-health healthy 0
[[ -f "${ARTIFACT_DIR}/ho-health/after-verification-nodepools.json" ]]
echo 'PASS: healthy verification also retains diagnostics'
