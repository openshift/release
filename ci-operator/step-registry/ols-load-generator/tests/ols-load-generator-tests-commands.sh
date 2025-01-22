#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
pushd /tmp

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

job_start=""
job_end=""
job_status=""
uuid=""
workload="ols-load-generator"
es_server="https://${ES_USERNAME}:${ES_PASSWORD}@search-perfscale-pro-wxrjvmobqs7gsyi3xvxkqmn7am.us-west-2.es.amazonaws.com"
additional_attributes='{}'

# Function to log job fingerprint
log_fingerprint() {
  pushd e2e-benchmarking/utils
  env JOB_START="$job_start" JOB_END="$job_end" JOB_STATUS="$job_status" UUID="$uuid" WORKLOAD="$workload" ES_SERVER="$es_server" ADDITIONAL_ATTRIBUTES="$additional_attributes" ./index.sh
  popd
}

# Function to run a command and handle failures
run_or_fail() {
  if ! "$@"; then
    echo "Error: Command '$*' failed."
    job_status="failure"
    job_end=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    log_fingerprint
    exit 1
  fi
}

# shellcheck disable=SC2153
IFS=',' read -ra test_durations <<< "$OLS_TEST_DURATIONS"
run_or_fail git clone https://github.com/openshift/lightspeed-operator.git --branch main --depth 1

# Cloning cloud-bulldozer's e2e repo to reuse fingerprint publishing utility script
LATEST_E2E_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
run_or_fail git clone https://github.com/cloud-bulldozer/e2e-benchmarking --branch $LATEST_E2E_TAG --depth 1

# Start the test loop
for OLS_TEST_DURATION in "${test_durations[@]}"; do
  # Reset job metadata at the start of each iteration
  uuid=$(uuidgen)
  job_status="success"
  job_start=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  job_end=""
  additional_attributes='{"ols_test_workers": '"${OLS_TEST_WORKERS}"', "ols_test_duration": "'"$OLS_TEST_DURATION"'"}'

  # Create namespace and set monitoring labels
  run_or_fail oc create namespace openshift-lightspeed
  run_or_fail oc label namespace openshift-lightspeed openshift.io/cluster-monitoring=true --overwrite=true

  # Deploy fake secret
  run_or_fail oc create secret generic fake-secret \
    --from-literal=apitoken="fake-api-key" \
    -n openshift-lightspeed

  # Deploy controller manager
  pushd lightspeed-operator
  run_or_fail make deploy
  run_or_fail oc wait --for=condition=Available -n openshift-lightspeed deployment lightspeed-operator-controller-manager --timeout=300s
  popd

  # Deploy olsconfig with fake values
  run_or_fail cat <<EOF | oc apply -f - -n openshift-lightspeed
apiVersion: ols.openshift.io/v1alpha1
kind: OLSConfig
metadata:
  name: cluster
  namespace: openshift-lightspeed
spec:
  llm:
    providers:
    - credentialsSecretRef:
        name: fake-secret
      models:
      - name: fake_model
      name: fake_provider
      type: fake_provider
  ols:
    defaultModel: fake_model
    defaultProvider: fake_provider
    enableDeveloperUI: false
    logLevel: INFO
    deployment:
      replicas: 1
EOF

  # Wait for the app server deployment
  run_or_fail oc wait --for=condition=Available -n openshift-lightspeed deployment lightspeed-app-server --timeout=300s

  # Deploy service monitor
  run_or_fail cat <<EOF | oc apply -f - -n openshift-lightspeed
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: ols-service-monitor
  namespace: openshift-lightspeed
  labels:
    app: ols
spec:
  selector:
    matchLabels:
      app.kubernetes.io/component: application-server
      app.kubernetes.io/managed-by: lightspeed-operator
      app.kubernetes.io/name: lightspeed-service-api
  endpoints:
  - port: "8443"
    path: /metrics
    interval: 30s
EOF

  # Wait for setup
  sleep 30

  # Create namespace and kubeconfig secret for load testing
  run_or_fail oc create namespace ols-load-test
  run_or_fail oc create secret generic kubeconfig-secret --from-file=kubeconfig=${KUBECONFIG} -n ols-load-test

  # Trigger the load test
  OLS_TEST_AUTH_TOKEN=$(oc whoami -t)
  run_or_fail cat <<EOF | oc apply -f -
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ols-load-generator-serviceaccount
  namespace: ols-load-test
rules:
- apiGroups: ["extensions", "apps", "batch", "security.openshift.io", "policy"]
  resources: ["deployments", "jobs", "pods", "services", "jobs/status", "podsecuritypolicies", "securitycontextconstraints"]
  verbs: ["use", "get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ols-load-generator-role
  namespace: ols-load-test
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ols-load-generator-serviceaccount
subjects:
- kind: ServiceAccount
  name: default
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ols-load-generator-orchestrator
  namespace: ols-load-test
  labels:
    ols-load-generator-component: orchestrator
spec:
  template:
    spec:
      containers:
      - name: ols-load-generator
        image: quay.io/vchalla/ols-load-generator:amd64
        securityContext:
          privileged: true
          env:
            - name: OLS_TEST_UUID
              value: "${uuid}"
            - name: OLS_TEST_HOST
              value: "https://lightspeed-app-server.openshift-lightspeed.svc.cluster.local:8443"
            - name: OLS_TEST_AUTH_TOKEN
              value: "${OLS_TEST_AUTH_TOKEN}"
            - name: OLS_TEST_DURATION
              value: "${OLS_TEST_DURATION}"
            - name: OLS_TEST_WORKERS
              value: "${OLS_TEST_WORKERS}"
            - name: OLS_TEST_PROFILES
              value: "${OLS_TEST_PROFILES}"
            - name: KUBECONFIG
              value: /etc/kubeconfig/kubeconfig
            - name: OLS_TEST_METRIC_STEP
              value: "${OLS_TEST_METRIC_STEP}"
            - name: OLS_TEST_ES_HOST
              value: "${es_server}"
            - name: OLS_TEST_ES_INDEX
              value: "${OLS_TEST_ES_INDEX}"
            - name: OLS_QUERY_ONLY
              value: "${OLS_QUERY_ONLY}"
          volumeMounts:
            - name: kubeconfig-volume
              mountPath: /etc/kubeconfig
              readOnly: true
          resources:
            requests:
              cpu: "1"
              memory: "512Mi"
          imagePullPolicy: Always
        restartPolicy: Never
        volumes:
          - name: kubeconfig-volume
            secret:
              secretName: kubeconfig-secret
    backoffLimit: 0
EOF

  # Wait for job completion
  run_or_fail oc wait --for=condition=complete job/ols-load-generator-orchestrator -n ols-load-test --timeout=600s

  # Clean up
  run_or_fail oc delete namespace ols-load-test
  run_or_fail oc wait --for=delete ns/ols-load-test --timeout=300s

  pushd lightspeed-operator
  run_or_fail make undeploy
  popd
  job_end=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  log_fingerprint

  sleep 300
done

popd
