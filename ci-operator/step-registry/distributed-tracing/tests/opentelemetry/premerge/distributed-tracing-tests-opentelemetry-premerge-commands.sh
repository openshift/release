#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Write a flat context file to SHARED_DIR so the qe-agent post-step can detect failures.
# SHARED_DIR only supports flat files (no subdirectories); subdirs are not propagated between steps.
function notify_qe_agent() {
    # The exit status of the step, before anything else runs: the step can fail before any JUnit file exists
    # (a missing image variable, a bad RUN_TESTS/SKIP_TESTS combination, the operator rollout timing out).
    local rc=$?
    local has_failures=false
    grep -rqE --include='*.xml' '<(failure|error)[ >]' "${ARTIFACT_DIR}" 2>/dev/null && has_failures=true
    [[ "${rc}" -ne 0 ]] && has_failures=true

    local i=0
    while IFS= read -r xml; do
        cp "${xml}" "${SHARED_DIR}/qe-agent-junit-${i}.xml" 2>/dev/null || true
        i=$((i + 1))
    done < <(find "${ARTIFACT_DIR}" -name "*.xml" 2>/dev/null)

    cat > "${SHARED_DIR}/qe-agent-context.json" <<CONTEXT
{
  "step_script_ref": "distributed-tracing/tests/opentelemetry/premerge/distributed-tracing-tests-opentelemetry-premerge-commands.sh",
  "has_test_failures": ${has_failures},
  "env": {
    "OPERATOR_IMG": "${OPERATOR_IMG:-}",
    "OTEL_COLLECTOR_IMAGE": "${OTEL_COLLECTOR_IMAGE:-}",
    "TARGETALLOCATOR_IMG": "${TARGETALLOCATOR_IMG:-}",
    "RUN_TESTS": "${RUN_TESTS:-}",
    "SKIP_TESTS": "${SKIP_TESTS:-}"
  }
}
CONTEXT
    echo "QE agent context and ${i} JUnit XML(s) written to SHARED_DIR (has_test_failures=${has_failures})"
}
trap notify_qe_agent EXIT

OPERATOR_NAMESPACE="opentelemetry-operator-system"
OPERATOR_DEPLOYMENT="opentelemetry-operator-controller-manager"
WEBHOOK_DEPLOYMENT="opentelemetry-operator-webhook"
# The full suite. Two directories run on their own, after everything else: tests/e2e-metadata-filters needs the
# metadata filter variables set on the operator first, and tests/e2e-openshift-tls-profile changes the cluster-wide
# TLS profile, which rolls out a MachineConfig update that disrupts any test running next to it, so it runs last.
FULL_SUITE="tests/e2e tests/e2e-autoscale tests/e2e-crd-validations tests/e2e-openshift tests/e2e-instrumentation
tests/e2e-pdb tests/e2e-otel tests/e2e-multi-instrumentation tests/e2e-targetallocator-cr tests/e2e-targetallocator
tests/e2e-prometheuscr tests/e2e-sidecar tests/e2e-metadata-filters tests/e2e-openshift-tls-profile"
METADATA_FILTERS_DIR="tests/e2e-metadata-filters"
TLS_PROFILE_DIR="tests/e2e-openshift-tls-profile"

if [[ -z "${OPERATOR_IMG:-}" || -z "${OTEL_COLLECTOR_IMAGE:-}" || -z "${TARGETALLOCATOR_IMG:-}" ]]; then
  echo "ERROR: OPERATOR_IMG, OTEL_COLLECTOR_IMAGE and TARGETALLOCATOR_IMG must be set. They are filled from the opentelemetry-operator-art, opentelemetry-collector and opentelemetry-target-allocator-art pipeline images."
  exit 1
fi
if [[ -n "${RUN_TESTS:-}" && -n "${SKIP_TESTS:-}" ]]; then
  echo "ERROR: RUN_TESTS and SKIP_TESTS cannot both be set. A job either names the tests to run or the tests to skip from the full suite."
  exit 1
fi
if [[ -z "${RUN_TESTS:-}" && -z "${SKIP_TESTS:-}" ]]; then
  echo "ERROR: neither RUN_TESTS nor SKIP_TESTS is set. A job names either the tests to run or the tests to skip from the full suite; a job config that sets neither is stale."
  exit 1
fi
echo "Operator image under test: ${OPERATOR_IMG}"
echo "Collector image under test: ${OTEL_COLLECTOR_IMAGE}"
echo "Target allocator image under test: ${TARGETALLOCATOR_IMG}"

# Copy the operator repository (the pull request source baked into the obs-tests-runner image) to a writable directory.
cp -R /tmp/opentelemetry-operator /tmp/otel-tests
cd /tmp/otel-tests

# The tests to run: exactly RUN_TESTS, or the full suite minus SKIP_TESTS.
if [[ -n "${RUN_TESTS:-}" ]]; then
  echo "Running the tests of RUN_TESTS: ${RUN_TESTS}"
  # shellcheck disable=SC2206 # RUN_TESTS is a space separated list
  selected=(${RUN_TESTS})
  for dir in "${selected[@]}"; do
    if [[ ! -d "${dir}" ]]; then
      echo "ERROR: the test directory ${dir} of RUN_TESTS does not exist in the repository."
      exit 1
    fi
  done
else
  echo "Running the full suite: ${FULL_SUITE}"
  # Remove the tests that cannot run on this OpenShift version, platform or architecture. Only paths under tests/
  # without a ".." component are accepted, so that nothing outside tests/ can be removed; globs are expanded by the
  # shell. The paths that exist and get removed are recorded, so that a suite directory removed as a whole (also
  # through a glob) is told apart from one that never existed.
  IFS=' ' read -ra SKIP_TEST_ARRAY <<< "${SKIP_TESTS}"
  INVALID_TESTS=""
  removed=()
  for test in "${SKIP_TEST_ARRAY[@]}"; do
    if [[ "${test}" != tests/* || "${test}" == *..* ]]; then
      INVALID_TESTS+=" ${test}"
      continue
    fi
    # shellcheck disable=SC2086 # the entry may be a glob
    for path in ${test}; do
      [[ -e "${path}" ]] && removed+=("${path}")
    done
  done
  if [[ -n "${INVALID_TESTS}" ]]; then
    echo "These test cases are not valid to be skipped:${INVALID_TESTS}"
  fi
  if [[ ${#removed[@]} -gt 0 ]]; then
    echo "Skipping tests: ${removed[*]}"
    rm -rf -- "${removed[@]}"
  fi
  # A suite directory that SKIP_TESTS removed as a whole is left out; a suite directory that does not exist on the
  # branch is an error of the suite list, not something to skip silently.
  selected=()
  for dir in ${FULL_SUITE}; do
    if [[ -d "${dir}" ]]; then
      selected+=("${dir}")
    elif [[ " ${removed[*]:-} " == *" ${dir} "* ]]; then
      echo "Suite directory ${dir} skipped as a whole."
    else
      echo "ERROR: the suite directory ${dir} does not exist in the repository; update the full suite list in this step."
      exit 1
    fi
  done
fi

# The metadata filters and the TLS profile tests run on their own after the rest, in that order (see FULL_SUITE).
main_dirs=()
run_metadata_filters=false
run_tls_profile=false
for dir in "${selected[@]}"; do
  case "${dir}" in
    "${METADATA_FILTERS_DIR}") run_metadata_filters=true ;;
    "${TLS_PROFILE_DIR}") run_tls_profile=true ;;
    *) main_dirs+=("${dir}") ;;
  esac
done

# Enable user workload monitoring
oc apply -f tests/e2e-openshift/otlp-metrics-traces/01-workload-monitoring.yaml

# Install Prometheus ScrapeConfig CRD, unless the cluster already has it. The version is the one the operator is built with.
if ! oc get crd scrapeconfigs.monitoring.coreos.com > /dev/null 2>&1; then
  oc create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/v0.92.0/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml
fi

# NAMESPACE conflicts with chainsaw.
unset NAMESPACE
oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | xargs -I {} oc label nodes {} ingress-ready=true --overwrite

# The tests are only meaningful if the installed operator is the image built from the PR. The bundle references it
# through the ci-operator substitution, so fail loudly when the substitution did not apply.
for deployment in "${OPERATOR_DEPLOYMENT}" "${WEBHOOK_DEPLOYMENT}"; do
  installed_image=$(oc -n "${OPERATOR_NAMESPACE}" get deployment "${deployment}" -o jsonpath='{.spec.template.spec.containers[0].image}')
  echo "Image of ${deployment}: ${installed_image}"
  if [[ "${installed_image##*@}" != "${OPERATOR_IMG##*@}" ]]; then
    echo "ERROR: ${deployment} does not run the operator image built from the PR (${OPERATOR_IMG})."
    exit 1
  fi
done

# Sets environment variables on the operator: set_operator_env NAME=VALUE [NAME=VALUE ...]
# The product CSV (bundle/art.yaml) sets the RELATED_IMAGE_* variables on the manager and on the webhook deployment,
# so both deployments are patched. The env of each container is rebuilt without any existing entry of the given
# variables, so the patch never creates duplicates, whether or not the installed bundle already carries them.
# Returns once OLM rolled out the patched deployments: each must carry exactly one entry of every variable with
# the requested value, and must be Available.
function set_operator_env() {
  local names='[]' entries='[]' pair csv_name patch deployment patched
  for pair in "$@"; do
    names=$(jq -c --arg n "${pair%%=*}" '. + [$n]' <<< "${names}")
    entries=$(jq -c --arg n "${pair%%=*}" --arg v "${pair#*=}" '. + [{"name": $n, "value": $v}]' <<< "${entries}")
  done
  echo "Setting the operator environment variables: $(jq -r 'map(.name) | join(" ")' <<< "${entries}")"

  if ! csv_name=$(oc get csv -n "${OPERATOR_NAMESPACE}" -o name | grep -m1 "opentelemetry-operator" | cut -d/ -f2); then
    echo "ERROR: no opentelemetry-operator CSV found in namespace ${OPERATOR_NAMESPACE}."
    exit 1
  fi
  patch=$(oc get csv "${csv_name}" -n "${OPERATOR_NAMESPACE}" -o json | jq -c \
    --arg manager "${OPERATOR_DEPLOYMENT}" \
    --arg webhook "${WEBHOOK_DEPLOYMENT}" \
    --argjson names "${names}" \
    --argjson entries "${entries}" '
    [.spec.install.spec.deployments | to_entries[] | select(.value.name == $manager or .value.name == $webhook) |
     {"op": "add",
      "path": "/spec/install/spec/deployments/\(.key)/spec/template/spec/containers/0/env",
      "value": (((.value.spec.template.spec.containers[0].env // [])
                 | map(select(.name as $n | ($names | index($n)) == null)))
                + $entries)}]')
  if [[ "$(jq length <<< "${patch}")" != "2" ]]; then
    echo "ERROR: expected the ${OPERATOR_DEPLOYMENT} and ${WEBHOOK_DEPLOYMENT} deployments in the CSV ${csv_name}."
    exit 1
  fi
  oc -n "${OPERATOR_NAMESPACE}" patch csv "${csv_name}" --type=json -p "${patch}"

  for deployment in "${OPERATOR_DEPLOYMENT}" "${WEBHOOK_DEPLOYMENT}"; do
    patched=false
    for _ in $(seq 1 30); do
      if oc -n "${OPERATOR_NAMESPACE}" get deployment "${deployment}" -o json | jq -e --argjson entries "${entries}" '
        (.spec.template.spec.containers[0].env // []) as $env
        | all($entries[]; . as $e | ([$env[] | select(.name == $e.name) | .value] == [$e.value]))' > /dev/null; then
        patched=true
        break
      fi
      sleep 10
    done
    if [[ "${patched}" != "true" ]]; then
      echo "ERROR: the deployment ${deployment} does not carry the requested environment variables."
      exit 1
    fi
    oc -n "${OPERATOR_NAMESPACE}" rollout status deployment "${deployment}" --timeout=5m
    oc -n "${OPERATOR_NAMESPACE}" wait --for=condition=Available deployment "${deployment}" --timeout=5m
  done
}

# Point the operator at the collector and target allocator images built in this CI run.
set_operator_env "RELATED_IMAGE_COLLECTOR=${OTEL_COLLECTOR_IMAGE}" "RELATED_IMAGE_TARGET_ALLOCATOR=${TARGETALLOCATOR_IMG}"

# The sidecar tests carry the label sidecar=native|legacy: native sidecars are used from OpenShift 4.16. The selector
# keeps the variant of this OpenShift version and every test without the label.
oc_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
oc_version_major=$(echo "$oc_version" | cut -d . -f 1)
oc_version_minor=$(echo "$oc_version" | cut -d . -f 2)
selector="sidecar!=native"
if [[ -n "$oc_version_major" ]] && { [[ "$oc_version_major" -ge 5 ]] || { [[ "$oc_version_major" -eq 4 ]] && [[ "$oc_version_minor" -ge 16 ]]; }; }; then
  selector="sidecar!=legacy"
fi

any_errors=false

if [[ ${#main_dirs[@]} -gt 0 ]]; then
  echo "=== Running: ${main_dirs[*]} (selector ${selector})"
  chainsaw test \
    --quiet \
    --report-name "junit_otel_e2e" \
    --report-path "$ARTIFACT_DIR" \
    --report-format "XML" \
    --selector "${selector}" \
    --test-dir \
    "${main_dirs[@]}" || any_errors=true
fi

if [[ "${run_metadata_filters}" == "true" ]]; then
  set_operator_env "ANNOTATIONS_FILTER=.*filter.out,config.*.gke.io.*" "LABELS_FILTER=.*filter.out"
  echo "=== Running: ${METADATA_FILTERS_DIR} (selector ${selector})"
  chainsaw test \
    --quiet \
    --report-name "junit_otel_e2e_metadata_filters" \
    --report-path "$ARTIFACT_DIR" \
    --report-format "XML" \
    --selector "${selector}" \
    --test-dir \
    "${METADATA_FILTERS_DIR}" || any_errors=true
fi

# Last: the TLS profile tests change the cluster-wide TLS profile and wait for the MachineConfig rollout.
if [[ "${run_tls_profile}" == "true" ]]; then
  echo "=== Running: ${TLS_PROFILE_DIR} (selector ${selector})"
  chainsaw test \
    --quiet \
    --report-name "junit_otel_e2e_tls_profile" \
    --report-path "$ARTIFACT_DIR" \
    --report-format "XML" \
    --selector "${selector}" \
    --test-dir \
    "${TLS_PROFILE_DIR}" || any_errors=true
fi

if $any_errors; then
  echo "Tests failed, check the logs for more details."
  exit 1
fi
echo "All the tests passed."
