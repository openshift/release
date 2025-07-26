#!/bin/bash
#set -o errexit
set -o nounset
#set -o pipefail

# Generate UUID for this test run
TEST_UUID=$(uuidgen)
echo "=== Starting etcd load test with UUID: $TEST_UUID ==="

# Export UUID for use in monitoring
export TEST_UUID
export ES_SERVER=${ES_SERVER:-""}
export ES_INDEX=${ES_INDEX:-"etcd-performance"}

# Test metadata
TEST_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
OCP_VERSION=$(oc version -o json | jq -r '.openshiftVersion')
ETCD_VERSION=$(oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].spec.containers[0].image}' | cut -d: -f2)

echo "=== Test Metadata ==="
echo "UUID: $TEST_UUID"
echo "Cluster: $CLUSTER_NAME"
echo "OCP Version: $OCP_VERSION"
echo "etcd Version: $ETCD_VERSION"
echo "Start Time: $TEST_START_TIME"
echo "======================="

# Function to log metrics with UUID
log_metrics() {
    local test_case="$1"
    local metric_name="$2" 
    local metric_value="$3"
    local timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    
    # Create metrics payload
    cat > /tmp/metric_${test_case}.json << EOF
{
  "uuid": "$TEST_UUID",
  "timestamp": "$timestamp",
  "clusterName": "$CLUSTER_NAME",
  "ocpVersion": "$OCP_VERSION",
  "etcdVersion": "$ETCD_VERSION",
  "testCase": "$test_case",
  "metricName": "$metric_name",
  "value": $metric_value,
  "testPhase": "execution"
}
EOF
    
    # If Elasticsearch is configured, send metrics
    if [[ -n "$ES_SERVER" ]]; then
        curl -X POST "$ES_SERVER/$ES_INDEX/_doc" \
             -H "Content-Type: application/json" \
             -d @/tmp/metric_${test_case}.json || echo "Failed to send metrics to ES"
    fi
    
    echo "METRIC: $test_case.$metric_name = $metric_value (UUID: $TEST_UUID)"
}

# Function to check etcd health and log metrics
check_etcd_health() {
    local test_phase="$1"
    echo "=== Checking etcd health after $test_phase ==="
    
    local healthy_endpoints=0
    local total_endpoints=0
    
    for pod in $(oc -n openshift-etcd get pods | grep etcd-ip | awk '{print $1}'); do
        total_endpoints=$((total_endpoints + 1))
        if oc -n openshift-etcd exec $pod -- etcdctl endpoint health >/dev/null 2>&1; then
            healthy_endpoints=$((healthy_endpoints + 1))
            echo "✓ $pod: HEALTHY"
        else
            echo "✗ $pod: UNHEALTHY"
        fi
    done
    
    log_metrics "$test_phase" "etcd_healthy_endpoints" "$healthy_endpoints"
    log_metrics "$test_phase" "etcd_total_endpoints" "$total_endpoints"
    
    # Get etcd metrics
    local db_size=$(oc -n openshift-etcd exec $pod -- etcdctl endpoint status --write-out=json 2>/dev/null | jq '.[0].Status.dbSize' 2>/dev/null || echo "0")
    log_metrics "$test_phase" "etcd_db_size_bytes" "$db_size"
}

#oc get route -A |grep ditty
oc get route -A |grep ditty || echo "No dittybopper"
NAME=${NAME:=""}

# Initial health check
check_etcd_health "baseline"

echo "=== TEST CASE 01: Creating Projects and ConfigMaps ==="
CASE01_START=$(date +%s)

# Get CA bundle
oc get cm/etcd-ca-bundle -n openshift-config -o=jsonpath='{.data.ca-bundle\.crt}' > /tmp/ca-bundle.crt

# Create projects with UUID labels
for i in {1..5}; do 
    oc new-project project-$i
    # Add UUID label to project for tracking
    oc label namespace project-$i test-uuid=$TEST_UUID
    oc label namespace project-$i test-case=projects-configmaps
    oc -n project-$i create configmap project-$i --from-file=/tmp/ca-bundle.crt
    # Label configmap too
    oc -n project-$i label configmap project-$i test-uuid=$TEST_UUID
done

CASE01_END=$(date +%s)
CASE01_DURATION=$((CASE01_END - CASE01_START))
log_metrics "projects_configmaps" "test_duration_seconds" "$CASE01_DURATION"
log_metrics "projects_configmaps" "projects_created" "5"
log_metrics "projects_configmaps" "configmaps_created" "5"

date; oc adm top node
check_etcd_health "projects_configmaps"

echo "=== TEST CASE 02: Creating Many Images ==="
CASE02_START=$(date +%s)

if ! oc get ns |grep multi-image >/dev/null; then
    oc create ns multi-image
    oc label namespace multi-image test-uuid=$TEST_UUID
    oc label namespace multi-image test-case=images
fi

cat<<EOF >/tmp/template_image.yaml
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: img-template
  labels:
    test-uuid: $TEST_UUID
    test-case: images
objects:
  - kind: Image
    apiVersion: image.openshift.io/v1
    metadata:
      name: "\${NAME}"
      labels:
        test-uuid: $TEST_UUID
        test-case: images
      creationTimestamp: null
    dockerImageReference: registry.redhat.io/ubi8/ruby-27:latest
    dockerImageMetadata:
      kind: DockerImage
      apiVersion: '1.0'
      Id: ''
      ContainerConfig: {}
      Config: {}
    dockerImageLayers: []
    dockerImageMetadataVersion: '1.0'
parameters:
  - name: NAME
EOF

for i in {1..3}; do
    oc -n multi-image process -f /tmp/template_image.yaml -p NAME=testImage-$i | oc -n multi-image create -f -
done

CASE02_END=$(date +%s)
CASE02_DURATION=$((CASE02_END - CASE02_START))
log_metrics "images" "test_duration_seconds" "$CASE02_DURATION"
log_metrics "images" "images_created" "3"

check_etcd_health "images"

echo "=== TEST CASE 03: Creating Many Secrets ==="
CASE03_START=$(date +%s)

# Create secret projects with UUID labels
for i in {1..2}; do 
    oc new-project sproject-$i
    oc label namespace sproject-$i test-uuid=$TEST_UUID
    oc label namespace sproject-$i test-case=secrets
    
    for j in {1..2}; do 
        oc -n sproject-$i create secret generic my-secret-$j \
            --from-literal=key1=supersecret \
            --from-literal=key2=topsecret
        oc -n sproject-$i label secret my-secret-$j test-uuid=$TEST_UUID
    done  
done

# Create large secrets
oc create ns my-namespace
oc label namespace my-namespace test-uuid=$TEST_UUID
oc label namespace my-namespace test-case=large-secrets

SECRET_NAME="my-large-secret"
NAMESPACE="my-namespace"

# Generate SSH key
ssh-keygen -t rsa -b 4096 -f /tmp/sshkey -N '' 
SSH_PRIVATE_KEY=$(cat /tmp/sshkey | base64 | tr -d '\n')
SSH_PUBLIC_KEY=$(cat /tmp/sshkey.pub | base64 | tr -d '\n')

# Generate token
TOKEN_VALUE=$(openssl rand -hex 32 | base64 | tr -d '\n')

# Generate certificate
openssl req -x509 -newkey rsa:4096 -keyout /tmp/tls.key -out /tmp/tls.crt -days 365 -nodes -subj "/CN=mydomain.com"
CERTIFICATE=$(cat /tmp/tls.crt | base64 | tr -d '\n')
PRIVATE_KEY=$(cat /tmp/tls.key | base64 | tr -d '\n')

# Create large secrets with UUID labels
for i in {3..5}; do 
    oc create secret generic ${SECRET_NAME}-$i -n $NAMESPACE \
        --from-literal=ssh-private-key="$SSH_PRIVATE_KEY" \
        --from-literal=ssh-public-key="$SSH_PUBLIC_KEY" \
        --from-literal=token="$TOKEN_VALUE" \
        --from-literal=tls.crt="$CERTIFICATE" \
        --from-literal=tls.key="$PRIVATE_KEY"
    oc -n $NAMESPACE label secret ${SECRET_NAME}-$i test-uuid=$TEST_UUID
done

CASE03_END=$(date +%s)
CASE03_DURATION=$((CASE03_END - CASE03_START))
log_metrics "secrets" "test_duration_seconds" "$CASE03_DURATION"
log_metrics "secrets" "small_secrets_created" "4"
log_metrics "secrets" "large_secrets_created" "3"

rm -f /tmp/sshkey /tmp/sshkey.pub /tmp/tls.crt /tmp/tls.key

check_etcd_health "secrets"

echo "=== Running etcd Analysis Tools ==="
cd /tmp || exit
git clone https://github.com/peterducai/etcd-tools.git
sleep 20

# Get admin credentials
export KUBECONFIG=/tmp/secret/kubeconfig
adminpassword=${adminpassword:=""}
if [[ -s /tmp/secret/kubeadmin-password ]]; then 
    adminpassword=$(cat /tmp/secret/kubeadmin-password)
fi
APIURL=$(grep 'server:' /tmp/secret/kubeconfig | awk -F 'server:' '{print $2}')
oc login $APIURL -u kubeadmin -p $adminpassword

date; oc adm top node; date; ls -lrt /tmp/etcd-tools
/tmp/etcd-tools/etcd-analyzer.sh; date

echo "=== Running FIO Test ==="
FIOTEST_START=$(date +%s)
/tmp/etcd-tools/fio_suite.sh

etc_masternode1=$(oc get node |grep master|awk '{print $1}'|tail -1)
oc debug -n openshift-etcd --quiet=true node/$etc_masternode1 -- chroot host bash -c "podman run --privileged --volume /var/lib/etcd:/test quay.io/peterducai/openshift-etcd-suite:latest fio"

FIOTEST_END=$(date +%s)
FIOTEST_DURATION=$((FIOTEST_END - FIOTEST_START))
log_metrics "fio_test" "test_duration_seconds" "$FIOTEST_DURATION"

# Final health check
check_etcd_health "final"

# Log test completion
TEST_END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TOTAL_DURATION=$(date +%s)
TOTAL_DURATION=$((TOTAL_DURATION - $(date -d "$TEST_START_TIME" +%s)))

echo "=== Test Completed ==="
echo "UUID: $TEST_UUID"
echo "Start: $TEST_START_TIME"
echo "End: $TEST_END_TIME" 
echo "Duration: ${TOTAL_DURATION}s"

# Create final test summary
cat > /tmp/test_summary_${TEST_UUID}.json << EOF
{
  "uuid": "$TEST_UUID",
  "startTime": "$TEST_START_TIME",
  "endTime": "$TEST_END_TIME", 
  "duration": $TOTAL_DURATION,
  "clusterName": "$CLUSTER_NAME",
  "ocpVersion": "$OCP_VERSION",
  "etcdVersion": "$ETCD_VERSION",
  "testStatus": "completed",
  "testCases": ["projects_configmaps", "images", "secrets", "fio_test"]
}
EOF

# Send final summary to Elasticsearch if configured
if [[ -n "$ES_SERVER" ]]; then
    curl -X POST "$ES_SERVER/$ES_INDEX/_doc" \
         -H "Content-Type: application/json" \
         -d @/tmp/test_summary_${TEST_UUID}.json || echo "Failed to send summary to ES"
fi

echo "Test summary saved to: /tmp/test_summary_${TEST_UUID}.json"

sleep 600 
