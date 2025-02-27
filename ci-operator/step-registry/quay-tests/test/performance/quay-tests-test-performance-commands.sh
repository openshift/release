#!/bin/bash

set -o nounset
# part 1, Quay performance test
QUAY_ROUTE=$(cat "$SHARED_DIR"/quayroute) #https://quayhostname
QUAY_OAUTH_TOKEN=$(cat "$SHARED_DIR"/quay_oauth2_token)

ELK_USERNAME=$(cat /var/run/quay-qe-elk-secret/username)
ELK_PASSWORD=$(cat /var/run/quay-qe-elk-secret/password)
ELK_HOST=$(cat /var/run/quay-qe-elk-secret/hostname)
ELK_SERVER="https://${ELK_USERNAME}:${ELK_PASSWORD}@${ELK_HOST}"
echo "ELK_SERVER: $ELK_SERVER"
echo "QUAY_ROUTE: $QUAY_ROUTE"

#create organization "perftest" and namespace "quay-perf" for Quay performance test
export quay_perf_organization="perftest"
export quay_perf_namespace="quay-perf"
export WORKLOAD="quay-load-test"
export RELEASE_STREAM="${QUAY_OPERATOR_CHANNEL}"

curl --location --request POST "${QUAY_ROUTE}/api/v1/organization/" \
    --header "Content-Type: application/json" \
    --header "Authorization: Bearer ${QUAY_OAUTH_TOKEN}" \
    --data-raw '{
        "name": "'"${quay_perf_organization}"'",
        "email": "testperf@testperf.com"
    }' -k

#   refer to https://github.com/quay/quay-performance-scripts

oc new-project "$quay_perf_namespace"
oc adm policy add-scc-to-user privileged system:serviceaccount:"$quay_perf_namespace":default

#Deploy Quay performance job to OCP namespace $quay_perf_namespace
QUAY_ROUTE=${QUAY_ROUTE#https://}  #remove "https://"
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

echo "the Perf Job needs about 3~4 hours to complete"
echo "check the OCP Quay Perf Job, if it complete, go to Kibana to generate index pattern and get Quay Perf metrics"

#wait until the quay perf testing job complete, and show the job status
oc get job -n "$quay_perf_namespace"
oc -n "$quay_perf_namespace" wait job/quay-perf-test-orchestrator --for=jsonpath='{.status.ready}'=0 --timeout=600s
date
start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

quayperf_pod_name=$(oc get pod -l job-name=quay-perf-test-orchestrator -n ${quay_perf_namespace} -o jsonpath='{.items[0].metadata.name}')
echo "$quayperf_pod_name"

if [[ -z "${quayperf_pod_name}" ]]; then
    echo "No quay-perf-test-orchestrator pod started, please check"
    exit 1
fi

sleep 120 #wait pod start

oc logs "$quayperf_pod_name" -n "${quay_perf_namespace}" | grep 'test_uuid' | sed -n 's/^.*test_uuid=\s*\(\S*\).*$/\1/p'>TEST_UUID
echo "TEST_UUID: $(cat TEST_UUID)"
echo $start_time

oc wait --for=condition=complete --timeout=6h job/quay-perf-test-orchestrator -n "$quay_perf_namespace"
date

end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo $end_time

# fetch UUID,JOB_START etc required data to dashboard http://dashboard.apps.sailplane.perf.lab.eng.rdu2.redhat.com/
echo "The Prow Job ID is: $PROW_JOB_ID"
   