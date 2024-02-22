#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Add manifest directory for kuttl
mkdir /tmp/kuttl-manifests

# If the DOWNSTREAM_TESTS_COMMIT variable is set, clone the repository with the specified commit
if [[ -n "${DOWNSTREAM_TESTS_COMMIT}" ]]; then
  git clone https://github.com/open-telemetry/opentelemetry-operator.git /tmp/otel-tests
  cd /tmp/otel-tests 
  git checkout -b downstream-release "${DOWNSTREAM_TESTS_COMMIT}"

  #Enable user workload monitoring
  oc apply -f tests/e2e-openshift/otlp-metrics-traces/01-workload-monitoring.yaml

  #Set parameters for running the test cases on OpenShift
  unset NAMESPACE
  OPERATOROPAMPBRIDGE_IMG=ghcr.io/open-telemetry/opentelemetry-operator/operator-opamp-bridge:v0.89.0 TARGETALLOCATOR_IMG=ghcr.io/open-telemetry/opentelemetry-operator/target-allocator:v0.89.0 SED_BIN="$(which sed)" ./hack/modify-test-images.sh
  sed -i 's/- -duration=1m/- -duration=6m/' tests/e2e-autoscale/autoscale/02-install.yaml
  oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | xargs -I {} oc label nodes {} ingress-ready=true

  # Remove test cases to be skipped from the test run
  IFS=' ' read -ra SKIP_TEST_ARRAY <<< "$SKIP_TESTS"
  SKIP_TESTS_TO_REMOVE=""
  INVALID_TESTS=""
  for test in "${SKIP_TEST_ARRAY[@]}"; do
    if [[ "$test" == tests/* ]]; then
      SKIP_TESTS_TO_REMOVE+=" $test"
    else
      INVALID_TESTS+=" $test"
    fi
  done

  if [[ -n "$INVALID_TESTS" ]]; then
    echo "These test cases are not valid to be skipped: $INVALID_TESTS"
  fi

  if [[ -n "$SKIP_TESTS_TO_REMOVE" ]]; then
    rm -rf $SKIP_TESTS_TO_REMOVE
  fi

  # Execute OpenTelemetry e2e tests
  KUBECONFIG=$KUBECONFIG kuttl test \
    --report=xml \
    --artifacts-dir="$ARTIFACT_DIR" \
    --parallel="$PARALLEL_TESTS" \
    --report-name="$REPORT_NAME" \
    --start-kind=false \
    --timeout="$TIMEOUT" \
    --manifest-dir=$MANIFEST_DIR \
    tests/e2e \
    tests/e2e-autoscale \
    tests/e2e-openshift \
    tests/e2e-prometheuscr \
    tests/e2e-instrumentation \
    tests/e2e-pdb \
    tests/e2e-opampbridge

  # Enable required feature gates.
  OTEL_CSV_NAME=$(oc get csv -n openshift-operators | grep "opentelemetry-operator" | awk '{print $1}')
  oc -n openshift-operators patch csv $OTEL_CSV_NAME --type=json -p '[{"op":"replace","path":"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args","value":["--metrics-addr=127.0.0.1:8080", "--enable-leader-election", "--zap-log-level=info", "--zap-time-encoding=rfc3339nano", "--feature-gates=+operator.autoinstrumentation.multi-instrumentation"]}]'
  sleep 10
  oc wait --for condition=Available -n openshift-operators deployment opentelemetry-operator-controller-manager

  # Execute OpenTelemetry e2e tests
  KUBECONFIG=$KUBECONFIG kuttl test \
    --report=xml \
    --artifacts-dir="$ARTIFACT_DIR" \
    --parallel="$PARALLEL_TESTS" \
    --report-name="$REPORT_NAME-2" \
    --start-kind=false \
    --timeout="$TIMEOUT" \
    --manifest-dir=$MANIFEST_DIR \
    tests/e2e-multi-instrumentation

else

  #Copy the opentelemetry-operator repo files to a writable directory by kuttl
  cp -R /tmp/opentelemetry-operator /tmp/opentelemetry-tests && cd /tmp/opentelemetry-tests

  #Enable user workload monitoring
  oc apply -f tests/e2e-openshift/otlp-metrics-traces/01-workload-monitoring.yaml

  #Set parameters for running the test cases on OpenShift
  unset NAMESPACE
  oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | xargs -I {} oc label nodes {} ingress-ready=true

  # Remove test cases to be skipped from the test run
  IFS=' ' read -ra SKIP_TEST_ARRAY <<< "$SKIP_TESTS"
  SKIP_TESTS_TO_REMOVE=""
  INVALID_TESTS=""
  for test in "${SKIP_TEST_ARRAY[@]}"; do
    if [[ "$test" == tests/* ]]; then
      SKIP_TESTS_TO_REMOVE+=" $test"
    else
      INVALID_TESTS+=" $test"
    fi
  done

  if [[ -n "$INVALID_TESTS" ]]; then
    echo "These test cases are not valid to be skipped: $INVALID_TESTS"
  fi

  if [[ -n "$SKIP_TESTS_TO_REMOVE" ]]; then
    rm -rf $SKIP_TESTS_TO_REMOVE
  fi

  # Enable required feature gates.
  OTEL_CSV_NAME=$(oc get csv -n opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
  oc -n opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args\",\"value\":[\"--metrics-addr=127.0.0.1:8080\", \"--enable-leader-election\", \"--zap-log-level=info\", \"--zap-time-encoding=rfc3339nano\", \"--target-allocator-image=${TARGETALLOCATOR_IMG}\", \"--operator-opamp-bridge-image=${OPERATOROPAMPBRIDGE_IMG}\", \"--feature-gates=+operator.autoinstrumentation.go,+operator.observability.prometheus,+operator.autoinstrumentation.nginx\"]}]"
  sleep 10
  oc wait --for condition=Available -n opentelemetry-operator deployment opentelemetry-operator-controller-manager

  # Execute OpenTelemetry e2e tests
  chainsaw test \
  --report-name "$REPORT_NAME" \
  --report-path "$ARTIFACT_DIR" \
  --report-format "XML" \
  --test-dir \
  tests/e2e \
  tests/e2e-autoscale \
  tests/e2e-openshift \
  tests/e2e-prometheuscr \
  tests/e2e-instrumentation \
  tests/e2e-pdb \
  tests/e2e-opampbridge \
  tests/e2e-targetallocator

  # Enable required feature gates.
  OTEL_CSV_NAME=$(oc get csv -n opentelemetry-operator | grep "opentelemetry-operator" | awk '{print $1}')
  oc -n opentelemetry-operator patch csv $OTEL_CSV_NAME --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/install/spec/deployments/0/spec/template/spec/containers/0/args\",\"value\":[\"--metrics-addr=127.0.0.1:8080\", \"--enable-leader-election\", \"--zap-log-level=info\", \"--zap-time-encoding=rfc3339nano\", \"--target-allocator-image=${TARGETALLOCATOR_IMG}\", \"--operator-opamp-bridge-image=${OPERATOROPAMPBRIDGE_IMG}\", \"--feature-gates=+operator.autoinstrumentation.multi-instrumentation\"]}]"
  sleep 10
  oc wait --for condition=Available -n opentelemetry-operator deployment opentelemetry-operator-controller-manager

  # Execute OpenTelemetry e2e tests
  chainsaw test \
  --report-name "$REPORT_NAME" \
  --report-path "$ARTIFACT_DIR" \
  --report-format "XML" \
  --test-dir \
  tests/e2e-multi-instrumentation
fi