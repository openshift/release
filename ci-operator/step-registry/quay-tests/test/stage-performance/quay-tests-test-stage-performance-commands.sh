#!/bin/bash
#refer to https://github.com/quay/quay-performance-scripts

set -o errexit
set -o nounset
set -o pipefail

# 1, Prepare Quay stage-performance test environment
QUAY_ROUTE="https://stage.quay.io"

STAGE_USERNAME=$(cat /var/run/stagequayqe/username)
STAGE_PASSWORD=$(cat /var/run/stagequayqe/password)
QUAY_OAUTH_TOKEN=$(cat /var/run/stagequayqe/oauth)

ELK_USERNAME=$(cat /var/run/quay-qe-elk-secret/username)
ELK_PASSWORD=$(cat /var/run/quay-qe-elk-secret/password)
ELK_HOST=$(cat /var/run/quay-qe-elk-secret/hostname)
ELK_SERVER="https://${ELK_USERNAME}:${ELK_PASSWORD}@${ELK_HOST}"
ADDITIONAL_PARAMS=$(printf '{"quayVersion": "%s"}' "${QUAY_OPERATOR_CHANNEL}")

#Create organization "perftest" and namespace "quay-perf" for Quay stage-performance test
export quay_perf_organization="perftest-${BUILD_ID}"
export quay_perf_namespace="quay-perf"

# if quay_perf_organization already exists, skip creation
perf_organization_exists=$(curl -s -o /dev/null -w "%{http_code}" \
  -X GET \
  -H "Authorization: Bearer ${QUAY_OAUTH_TOKEN}" \
  "https://stage.quay.io/api/v1/organization/${quay_perf_organization}")
if [ "$perf_organization_exists" -eq 200 ]; then
  echo "Organization ${quay_perf_organization} already exists, skipping creation."
else 
  # If it does not exist, create it
  curl --fail --silent --show-error --location --request POST "${QUAY_ROUTE}/api/v1/organization/" \
    --header "Content-Type: application/json" \
    --header "Authorization: Bearer ${QUAY_OAUTH_TOKEN}" \
    --data-raw '{
        "name": "'"${quay_perf_organization}"'",
        "email": "testperf@testperf.com"
    }' -k
fi

oc new-project "$quay_perf_namespace"
oc adm policy add-scc-to-user privileged system:serviceaccount:"$quay_perf_namespace":default

# 2, Deploy Quay stage-performance test job

QUAY_ROUTE=${QUAY_ROUTE#https://} #remove "https://"

cleanup_repositories() {
  echo "Cleaning up repositories in organization ${quay_perf_organization}..."
  repos=$(curl -s -H "Authorization: Bearer ${QUAY_OAUTH_TOKEN}" \
    "https://$QUAY_ROUTE/api/v1/repository?namespace=${quay_perf_organization}" \
    | jq -r '.repositories[]?.name' || true)

  for repo in $repos; do
    echo "Deleting repository: ${quay_perf_organization}/${repo}"
    curl -s -X DELETE \
      -H "Authorization: Bearer ${QUAY_OAUTH_TOKEN}" \
      "https://$QUAY_ROUTE/api/v1/repository/${quay_perf_organization}/${repo}" -o /dev/null || true
  done
  echo "Repository cleanup complete."
}

trap cleanup_repositories EXIT

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
        readinessProbe:
          tcpSocket:
            port: 6379
          initialDelaySeconds: 5
          periodSeconds: 5
        resources:
          requests:
            cpu: 100m
            memory: 256Mi
          limits:
            cpu: 500m
            memory: 512Mi
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
          - name: QUAY_USERNAME
            value: "${STAGE_USERNAME}"   
          - name: QUAY_PASSWORD
            value: "${STAGE_PASSWORD}"     
        resources:
          requests:
            cpu: "1"
            memory: "512Mi"
        imagePullPolicy: Always
      restartPolicy: Never
  backoffLimit: 0

EOF

echo "the Perf Job needs about 1 hour to complete"
echo "check the OCP Quay Perf Job, if it complete, go to AWS OpenSearch to generate index pattern and get Quay Perf metrics"

#Wait until the quay perf testing job complete, and show the job status
oc get job -n "$quay_perf_namespace"
oc -n "$quay_perf_namespace" wait deployment/redis --for=condition=Available --timeout=600s

# 3, Wait until the job complete

start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
oc wait pod -l job-name=quay-perf-test-orchestrator \
  --for=condition=PodScheduled --timeout=600s -n "$quay_perf_namespace"
quayperf_pod_name=$(oc get pod -l job-name=quay-perf-test-orchestrator -n ${quay_perf_namespace} -o jsonpath='{.items[0].metadata.name}')

if [[ -z "${quayperf_pod_name}" ]]; then
  echo "No quay-perf-test-orchestrator pod started, please check"
  exit 1
fi

oc wait pod -l job-name=quay-perf-test-orchestrator \
  --for=condition=Ready --timeout=600s -n "$quay_perf_namespace"

# Fetch UUID,JOB_START etc required data to dashboard
TEST_UUID=""
for _ in {1..30}; do
  TEST_UUID=$(oc logs "$quayperf_pod_name" -n "${quay_perf_namespace}" 2>/dev/null \
    | sed -n 's/^.*test_uuid=[[:space:]]*\([^[:space:]]*\).*$/\1/p' | sed -n '1p' || true)
  if [[ -n "${TEST_UUID}" ]]; then
    break
  fi
  sleep 10
done
if [[ -z "${TEST_UUID}" ]]; then
  echo "Unable to obtain the performance test UUID"
  exit 1
fi
echo "job start: $start_time"

JOB_STATUS="Success"
if ! oc wait --for=condition=complete --timeout=6h job/quay-perf-test-orchestrator -n "$quay_perf_namespace"; then
  JOB_STATUS="Failed"
fi
date

end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "job end $end_time and status $JOB_STATUS"
sleep 10
# 4, Send the stage-performance test data to ELK
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
source utility/e2e-benchmarking.sh
echo "Quay stage performance test finised"

if [[ "${JOB_STATUS}" != "Success" ]]; then
  exit 1
fi
