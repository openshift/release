#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Write a flat context file to SHARED_DIR so the qe-agent post-step can detect failures.
# SHARED_DIR only supports flat files (no subdirectories); subdirs are not propagated between steps.
function notify_qe_agent() {
    local has_failures=false
    grep -rqE '<(failure|error)[ >]' "${ARTIFACT_DIR}" 2>/dev/null && has_failures=true

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
    "TARGETALLOCATOR_IMG": "${TARGETALLOCATOR_IMG:-}"
  }
}
CONTEXT
    echo "QE agent context and ${i} JUnit XML(s) written to SHARED_DIR (has_test_failures=${has_failures})"
}
trap notify_qe_agent EXIT

OPERATOR_NAMESPACE="opentelemetry-operator-system"
OPERATOR_DEPLOYMENT="opentelemetry-operator-controller-manager"
WEBHOOK_DEPLOYMENT="opentelemetry-operator-webhook"

if [[ -z "${OPERATOR_IMG:-}" || -z "${OTEL_COLLECTOR_IMAGE:-}" || -z "${TARGETALLOCATOR_IMG:-}" ]]; then
  echo "ERROR: OPERATOR_IMG, OTEL_COLLECTOR_IMAGE and TARGETALLOCATOR_IMG must be set. They are filled from the opentelemetry-operator-art, opentelemetry-collector and opentelemetry-target-allocator-art pipeline images."
  exit 1
fi
echo "Operator image under test: ${OPERATOR_IMG}"
echo "Collector image under test: ${OTEL_COLLECTOR_IMAGE}"
echo "Target allocator image under test: ${TARGETALLOCATOR_IMG}"

# Copy the operator repository (the pull request source baked into the obs-tests-runner image) to a writable directory.
cp -R /tmp/opentelemetry-operator /tmp/otel-tests
cd /tmp/otel-tests

# Enable user workload monitoring
oc apply -f tests/e2e-openshift/otlp-metrics-traces/01-workload-monitoring.yaml

# Install Prometheus ScrapeConfig CRD
kubectl create -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml

# NAMESPACE conflicts with chainsaw.
unset NAMESPACE
oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | xargs -I {} oc label nodes {} ingress-ready=true

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

# Point the operator at the collector and target allocator images built in this CI run.
# The product CSV (bundle/art.yaml) sets both variables on the manager and on the webhook deployment, so set both.
# The env of each container is rebuilt without any existing entry of these variables, so the patch never creates
# duplicates, whether or not the installed bundle already carries them.
CSV_NAME=$(oc get csv -n "${OPERATOR_NAMESPACE}" -o name | grep -m1 "opentelemetry-operator" | cut -d/ -f2)
PATCH=$(oc get csv "${CSV_NAME}" -n "${OPERATOR_NAMESPACE}" -o json | jq -c \
  --arg manager "${OPERATOR_DEPLOYMENT}" \
  --arg webhook "${WEBHOOK_DEPLOYMENT}" \
  --arg collector "${OTEL_COLLECTOR_IMAGE}" \
  --arg ta "${TARGETALLOCATOR_IMG}" '
  [.spec.install.spec.deployments | to_entries[] | select(.value.name == $manager or .value.name == $webhook) |
   {"op": "add",
    "path": "/spec/install/spec/deployments/\(.key)/spec/template/spec/containers/0/env",
    "value": (((.value.spec.template.spec.containers[0].env // [])
               | map(select(.name != "RELATED_IMAGE_COLLECTOR" and .name != "RELATED_IMAGE_TARGET_ALLOCATOR")))
              + [{"name": "RELATED_IMAGE_COLLECTOR", "value": $collector},
                 {"name": "RELATED_IMAGE_TARGET_ALLOCATOR", "value": $ta}])}]')
if [[ "$(jq length <<< "${PATCH}")" != "2" ]]; then
  echo "ERROR: expected the ${OPERATOR_DEPLOYMENT} and ${WEBHOOK_DEPLOYMENT} deployments in the CSV ${CSV_NAME}."
  exit 1
fi
oc -n "${OPERATOR_NAMESPACE}" patch csv "${CSV_NAME}" --type=json -p "${PATCH}"

# Wait until OLM rolled out the patched deployments: each must carry exactly one entry of both variables with the
# requested image, and must be Available.
function has_expected_images() {
  oc -n "${OPERATOR_NAMESPACE}" get deployment "$1" -o json | jq -e \
    --arg collector "${OTEL_COLLECTOR_IMAGE}" \
    --arg ta "${TARGETALLOCATOR_IMG}" '
    .spec.template.spec.containers[0].env as $env
    | ([$env[] | select(.name == "RELATED_IMAGE_COLLECTOR") | .value] == [$collector])
      and ([$env[] | select(.name == "RELATED_IMAGE_TARGET_ALLOCATOR") | .value] == [$ta])' > /dev/null
}
for deployment in "${OPERATOR_DEPLOYMENT}" "${WEBHOOK_DEPLOYMENT}"; do
  patched=false
  for _ in $(seq 1 30); do
    if has_expected_images "${deployment}"; then
      patched=true
      break
    fi
    sleep 10
  done
  if [[ "${patched}" != "true" ]]; then
    echo "ERROR: the deployment ${deployment} does not carry the collector and target allocator images under test."
    exit 1
  fi
  oc -n "${OPERATOR_NAMESPACE}" rollout status deployment "${deployment}" --timeout=5m
  oc -n "${OPERATOR_NAMESPACE}" wait --for=condition=Available deployment "${deployment}" --timeout=5m
done

# Determine OpenShift version and set sidecar selector: native sidecars are used from OpenShift 4.16.
oc_version=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)
oc_version_major=$(echo "$oc_version" | cut -d . -f 1)
oc_version_minor=$(echo "$oc_version" | cut -d . -f 2)
selector="sidecar=legacy"
if [[ -n "$oc_version_major" ]] && { [[ "$oc_version_major" -ge 5 ]] || { [[ "$oc_version_major" -eq 4 ]] && [[ "$oc_version_minor" -ge 16 ]]; }; }; then
  selector="sidecar=native"
fi

any_errors=false

# Execute the critical OpenTelemetry e2e tests
# shellcheck disable=SC2086 # TEST_DIRS is a space separated list
chainsaw test \
  --quiet \
  --report-name "junit_otel_e2e_pre_merge" \
  --report-path "$ARTIFACT_DIR" \
  --report-format "XML" \
  --test-dir \
  ${TEST_DIRS} || any_errors=true

# Execute the sidecar tests with the version dependent selector
if [[ -n "${SIDECAR_TEST_DIRS:-}" ]]; then
  # shellcheck disable=SC2086 # SIDECAR_TEST_DIRS is a space separated list
  chainsaw test \
    --quiet \
    --report-name "junit_otel_e2e_pre_merge_sidecar" \
    --report-path "$ARTIFACT_DIR" \
    --report-format "XML" \
    --selector "$selector" \
    --test-dir \
    ${SIDECAR_TEST_DIRS} || any_errors=true
fi

if $any_errors; then
  echo "Tests failed, check the logs for more details."
  exit 1
fi
echo "All the tests passed."
