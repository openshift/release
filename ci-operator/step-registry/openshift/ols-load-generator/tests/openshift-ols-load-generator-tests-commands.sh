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
es_server="https://${ES_USERNAME}:${ES_PASSWORD}@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
additional_attributes='{}'

# Function to log job fingerprint
log_fingerprint() {
  # Cloning cloud-bulldozer's e2e repo to reuse fingerprint publishing utility script
  pushd e2e-benchmarking/utils
  env JOB_START="$job_start" JOB_END="$job_end" JOB_STATUS="$job_status" UUID="$uuid" WORKLOAD="$workload" ES_SERVER="$es_server" ADDITIONAL_PARAMS="$additional_attributes" ./index.sh
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
LATEST_E2E_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
run_or_fail git clone https://github.com/cloud-bulldozer/e2e-benchmarking --branch $LATEST_E2E_TAG --depth 1

export GOPATH=/tmp/go
export GOROOT=/usr/lib/golang
export GOBIN=/tmp/go/bin
export GOMODCACHE=/tmp/go/pkg/mod
export PATH=$GOROOT/bin:$GOBIN:$PATH
mkdir -p $GOPATH/bin $GOMODCACHE

# Start the test loop
for OLS_TEST_DURATION in "${test_durations[@]}"; do
  # Reset job metadata at the start of each iteration
  uuid=$(uuidgen)
  job_status="success"
  job_start=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  job_end=""
  additional_attributes='{"olsTestWorkers": '"${OLS_TEST_WORKERS}"', "olsTestDuration": "'"$OLS_TEST_DURATION"'"}'

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
  run_or_fail oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:openshift-lightspeed:lightspeed-operator-controller-manager
  run_or_fail oc wait --for=condition=Available -n openshift-lightspeed deployment lightspeed-operator-controller-manager --timeout=600s
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
  sleep 60
  run_or_fail oc wait --for=condition=Available -n openshift-lightspeed deployment lightspeed-app-server --timeout=600s
  LOG_START_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  COMMIT_ID=$(skopeo inspect docker://quay.io/openshift-lightspeed/lightspeed-service-api:latest | jq -r '.Labels."vcs-ref"')
  run_or_fail echo "Possible commit ID under test: $COMMIT_ID"

  # Create namespace and kubeconfig secret for load testing
  run_or_fail oc create namespace ols-load-test
  run_or_fail oc create secret generic kubeconfig-secret --from-file=kubeconfig=${KUBECONFIG} -n ols-load-test

  # Create and configure auth token
  set +x
  run_or_fail oc project openshift-lightspeed
  run_or_fail oc adm policy add-cluster-role-to-user cluster-admin system:serviceaccount:openshift-lightspeed:lightspeed-app-server
  OLS_TEST_AUTH_TOKEN=$(oc create token lightspeed-app-server -n openshift-lightspeed --duration=4294967296s)
  set -x

  # Trigger the load test
  run_or_fail cat <<EOF | oc apply -f -
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ols-load-generator-serviceaccount
  namespace: ols-load-test
rules:
- apiGroups: ["extensions", "apps", "batch"]
  resources: ["deployments", "jobs", "pods", "services", "jobs/status"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["security.openshift.io"]
  resources: ["securitycontextconstraints"]
  verbs: ["use"]
  resourceNames: ["privileged"]
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
  namespace: ols-load-test
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ols-load-generator-orchestrator
  namespace: ols-load-test
  labels:
    ols-load-generator-component: orchestrator
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/worker
                operator: In
                values:
                - ""
        podAffinity: {}
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app.kubernetes.io/component
                    operator: In
                    values:
                      - application-server
                  - key: app.kubernetes.io/name
                    operator: In
                    values:
                      - lightspeed-service-api
                  - key: app.kubernetes.io/part-of
                    operator: In
                    values:
                      - openshift-lightspeed
                  - key: app.kubernetes.io/managed-by
                    operator: In
                    values:
                      - lightspeed-operator
              topologyKey: "kubernetes.io/hostname"
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
      volumes:
        - name: kubeconfig-volume
          secret:
            secretName: kubeconfig-secret
  backoffLimit: 0
EOF

  # Wait for job completion
  sleep 60
  run_or_fail oc wait --for=condition=complete job/ols-load-generator-orchestrator -n ols-load-test --timeout=60000s

  # Clean up
  run_or_fail oc delete namespace ols-load-test
  run_or_fail oc wait --for=delete ns/ols-load-test --timeout=600s
  run_or_fail oc logs -n openshift-lightspeed deployment/lightspeed-app-server --since-time="$LOG_START_TIME" > ols_${OLS_TEST_WORKERS}_${OLS_TEST_DURATION}.txt
  run_or_fail cp ols_${OLS_TEST_WORKERS}_${OLS_TEST_DURATION}.txt ${ARTIFACT_DIR}/ols_${OLS_TEST_WORKERS}_${OLS_TEST_DURATION}.txt

  pushd lightspeed-operator
  run_or_fail make undeploy
  popd
  job_end=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  log_fingerprint

  sleep 300
done

popd
