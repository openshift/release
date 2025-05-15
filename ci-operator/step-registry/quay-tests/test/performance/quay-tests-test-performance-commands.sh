#!/bin/bash
#refer to https://github.com/quay/quay-performance-scripts

set -o nounset

# 1, Prepare Quay performance test environment

QUAY_ROUTE=$(cat "$SHARED_DIR"/quayroute) #https://quayhostname
QUAY_OAUTH_TOKEN=$(cat "$SHARED_DIR"/quay_oauth2_token)

ELK_USERNAME=$(cat /var/run/quay-qe-elk-secret/username)
ELK_PASSWORD=$(cat /var/run/quay-qe-elk-secret/password)
ELK_HOST=$(cat /var/run/quay-qe-elk-secret/hostname)
ELK_SERVER="https://${ELK_USERNAME}:${ELK_PASSWORD}@${ELK_HOST}"
ADDITIONAL_PARAMS=$(printf '{"quayVersion": "%s"}' "${QUAY_OPERATOR_CHANNEL}")
echo "QUAY_ROUTE: $QUAY_ROUTE"

#Create organization "perftest" and namespace "quay-perf" for Quay performance test
export quay_perf_organization="perftest"
export quay_perf_namespace="quay-perf"
export WORKLOAD="quay-load-test"

curl --location --request POST "${QUAY_ROUTE}/api/v1/organization/" \
  --header "Content-Type: application/json" \
  --header "Authorization: Bearer ${QUAY_OAUTH_TOKEN}" \
  --data-raw '{
        "name": "'"${quay_perf_organization}"'",
        "email": "testperf@testperf.com"
    }' -k

oc new-project "$quay_perf_namespace"
oc adm policy add-scc-to-user privileged system:serviceaccount:"$quay_perf_namespace":default

# 2, Deploy Quay performance test job

QUAY_ROUTE=${QUAY_ROUTE#https://} #remove "https://"
cat <<EOF | oc apply -f -
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: quay-perf-test-serviceaccount
rules:
- apiGroups: ["extensions", "apps", "batch", "security.openshift.io", "policy"]
  resources: ["deployments", "jobs", "pods", "services", "jobs/status", "podsecuritypolicies", "securitycontextconstraints"]
  verbs: ["use", "get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: quay-perf-test-role
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: quay-perf-test-serviceaccount
subjects:
- kind: ServiceAccount
  name: default
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis
  labels:
    quay-perf-test-component: redis
spec:
  replicas: 1 
  selector:
    matchLabels:
      quay-perf-test-component: redis
  template:
    metadata:
      labels:
        quay-perf-test-component: redis
    spec:
      containers:
      - name: redis-master
        image: registry.access.redhat.com/rhscl/redis-32-rhel7
        imagePullPolicy: "IfNotPresent"
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: redis
  labels:
    quay-perf-test-component: redis-service
spec:
  ports:
    - port: 6379
  selector:
    quay-perf-test-component: redis
---
apiVersion: batch/v1
kind: Job
metadata:
  name: quay-perf-test-orchestrator
  labels:
    quay-perf-test-component: orchestrator
spec:
  template:
    spec:
      containers:
      - name: python
        image: quay.io/quay-qetest/quay-load:latest
        securityContext:
          privileged: true
        env:
          - name: QUAY_HOST
            value: "${QUAY_ROUTE}"
          - name: QUAY_OAUTH_TOKEN
            value: "${QUAY_OAUTH_TOKEN}"
          - name: QUAY_ORG
            value: "${quay_perf_organization}"
          - name: ES_HOST
            value: "${ELK_SERVER}"
          - name: ES_PORT
            value: "443"
          - name: PYTHONUNBUFFERED
            value: "0"
          - name: ES_INDEX
            value: "quay-vegeta"
          - name: PUSH_PULL_IMAGE
            value: "quay.io/quay-qetest/quay-load:latest"
          - name: PUSH_PULL_ES_INDEX
            value: "quay-push-pull"
          - name: PUSH_PULL_NUMBERS
            value:  "${PUSH_PULL_NUMBERS}"
          - name: TARGET_HIT_SIZE
            value: "${HITSIZE}"
          - name: CONCURRENCY
            value: "${CONCURRENCY}"
          - name: TEST_NAMESPACE
            value: "${quay_perf_namespace}"
          - name: TEST_PHASES
            value: "${TEST_PHASES}"
            # value: "LOAD,RUN,DELETE"
        resources:
          requests:
            cpu: "1"
            memory: "512Mi"
        imagePullPolicy: Always
      restartPolicy: Never
  backoffLimit: 0

EOF

echo "the Perf Job needs about 2~3 hours to complete"
echo "check the OCP Quay Perf Job, if it complete, go to AWS OpenSearch to generate index pattern and get Quay Perf metrics"

#Wait until the quay perf testing job complete, and show the job status
oc get job -n "$quay_perf_namespace"
oc -n "$quay_perf_namespace" wait job/quay-perf-test-orchestrator --for=jsonpath='{.status.ready}'=0 --timeout=600s

# 3, Wait until the job complete

start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
quayperf_pod_name=$(oc get pod -l job-name=quay-perf-test-orchestrator -n ${quay_perf_namespace} -o jsonpath='{.items[0].metadata.name}')

if [[ -z "${quayperf_pod_name}" ]]; then
  echo "No quay-perf-test-orchestrator pod started, please check"
  exit 1
fi

sleep 120 #wait pod start

# Fetch UUID,JOB_START etc required data to dashboard 
TEST_UUID=$(oc logs "$quayperf_pod_name" -n "${quay_perf_namespace}" | grep 'test_uuid' | sed -n 's/^.*test_uuid=\s*\(\S*\).*$/\1/p')
echo "job start: $start_time"

JOB_STATUS="Success"
oc wait --for=condition=complete --timeout=6h job/quay-perf-test-orchestrator -n "$quay_perf_namespace"
if [ $? -ne 0 ]; then
  JOB_STATUS="Failed"
fi
date

end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "job end $end_time and status $JOB_STATUS"

# 4, Send the performance test data to ELK
# original: https://github.com/cloud-bulldozer/e2e-benchmarking/blob/master/utils/index.sh

export ES_SERVER="${ELK_SERVER}"
export BUILD_ID="${BUILD_ID}"
export UUID="${TEST_UUID}"
export JOB_STATUS="$JOB_STATUS"
export JOB_START="$start_time"
export JOB_END="$end_time"
export WORKLOAD="quay-load-test"
export TEST_PHASES="${TEST_PHASES}"
export HITSIZE
export CONCURRENCY
export PUSH_PULL_NUMBERS
export ADDITIONAL_PARAMS

# Invoke index.sh to send data to dashboad http://dashboard.apps.sailplane.perf.lab.eng.rdu2.redhat.com/ 
source utility/e2e-benchmarking.sh || true
echo "Quay performance test finised"
