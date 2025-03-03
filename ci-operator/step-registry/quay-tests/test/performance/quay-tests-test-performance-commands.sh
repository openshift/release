#!/bin/bash

set -o nounset

pwd
ls -al
echo "current directory is: $(pwd)"

# 1, Setup Quay performance test environment

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

echo "the Perf Job needs about 3~4 hours to complete"
echo "check the OCP Quay Perf Job, if it complete, go to Kibana to generate index pattern and get Quay Perf metrics"

#wait until the quay perf testing job complete, and show the job status
oc get job -n "$quay_perf_namespace"
oc -n "$quay_perf_namespace" wait job/quay-perf-test-orchestrator --for=jsonpath='{.status.ready}'=0 --timeout=600s

# 3, Wait until the job complete

date
start_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

quayperf_pod_name=$(oc get pod -l job-name=quay-perf-test-orchestrator -n ${quay_perf_namespace} -o jsonpath='{.items[0].metadata.name}')
echo "$quayperf_pod_name"

if [[ -z "${quayperf_pod_name}" ]]; then
  echo "No quay-perf-test-orchestrator pod started, please check"
  exit 1
fi

sleep 120 #wait pod start

TEST_UUID=$(oc logs "$quayperf_pod_name" -n "${quay_perf_namespace}" | grep 'test_uuid' | sed -n 's/^.*test_uuid=\s*\(\S*\).*$/\1/p')
echo "$TEST_UUID"
echo "job start: $start_time"

JOB_STATUS="Success"
oc wait --for=condition=complete --timeout=6h job/quay-perf-test-orchestrator -n "$quay_perf_namespace"
if [ $? -ne 0 ]; then
  JOB_STATUS="Failed"
fi
date

end_time=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "job end $end_time"

# fetch UUID,JOB_START etc required data to dashboard http://dashboard.apps.sailplane.perf.lab.eng.rdu2.redhat.com/
echo "The Prow Job ID is: $PROW_JOB_ID"
# echo "The Prow Job URL is: $PROW_JOB_URL"


# 4, Send the performance test data to ELK
# https://github.com/cloud-bulldozer/e2e-benchmarking/blob/master/utils/index.sh
# setup(){
#     if [[ -n $AIRFLOW_CTX_DAG_ID ]]; then
#         export job_id=${AIRFLOW_CTX_DAG_ID}
#         export execution_date=${AIRFLOW_CTX_EXECUTION_DATE}
#         export job_run_id=${AIRFLOW_CTX_DAG_RUN_ID}
#         export ci="AIRFLOW"
#         # Get Airflow URL
#         airflow_base_url="http://$(kubectl get route/airflow -n airflow -o jsonpath='{.spec.host}')"
#         export ${airflow_base_url}
#         # Setup Kubeconfig
#         export KUBECONFIG=/home/airflow/auth/config
#         curl -sS https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz | tar xz oc
#         PATH=$PATH:/home/airflow/.local/bin:$(pwd)
#         export $PATH
#         if echo "$job_run_id" | grep -qi "scheduled"; then
#             job_type="scheduled"
#         elif echo "$job_run_id" | grep -qi "backfill"; then
#             job_type="backfill"
#         elif echo "$job_run_id" | grep -qi "dataset"; then
#             job_type="dataset dependancy"
#         else
#             job_type="manual"
#         fi
#     elif [[ -n $PROW_JOB_ID ]]; then
#         export ci="PROW"
#         export prow_base_url="https://prow.ci.openshift.org/view/gs/origin-ci-test/logs"
#         export prow_pr_base_url="https://prow.ci.openshift.org/view/gs/test-platform-results/pr-logs/pull/openshift_release"
#         job_type=${JOB_TYPE}
#         if [[ "${job_type}" == "presubmit" && "${JOB_NAME}" == *pull* ]]; then
#             # Indicates a ci test triggered in PR against source code
#             job_type="pull"
#         fi
#         if [[ "${job_type}" == "presubmit" && "${JOB_NAME}" == *rehearse* ]]; then
#             # Indicates a rehearsel in PR against openshift/release repo
#             job_type="rehearse"
#         fi

#     elif [[ -n $BUILD_ID ]]; then
#         export ci="JENKINS"
#         export build_url="${BUILD_URL}api/json"
#         set +eo pipefail
#         LATEST_CAUSE=$(curl -s ${build_url} | tr '\n' ' ' | jq -r '.actions[].causes[].shortDescription' 2>/dev/null | grep -v "null" | head -n 1)
#         echo "latest cause $LATEST_CAUSE"
#         if echo "$LATEST_CAUSE" | grep -iq "SCM"; then
#             job_type="scm trigger"
#         elif echo "$LATEST_CAUSE" | grep -iq "timer"; then
#             job_type="time trigger"
#         elif echo "$LATEST_CAUSE" | grep -iq "upstream"; then
#             job_type="upstream trigger"
#         elif echo "$LATEST_CAUSE" | grep -iq "user"; then
#             job_type="manual trigger"
#         else
#             job_type="unknown"
#         fi
#         set -eo pipefail
#     fi
#     export job_type
#     export UUID=$UUID
#     # Elasticsearch Config
#     export ES_SERVER=$ES_SERVER
#     export WORKLOAD=$WORKLOAD
#     export ES_INDEX=$ES_INDEX
#     # Get OpenShift cluster details
#     cluster_name=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}') || echo "Cluster Install Failed"
#     cluster_version=$(oc version -o json | jq -r '.openshiftVersion') || echo "Cluster Install Failed"
#     export RELEASE_STREAM=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '-' -f1-2) || echo "Cluster Install Failed"
#     network_type=$(oc get network.config/cluster -o jsonpath='{.status.networkType}') || echo "Cluster Install Failed"
#     platform=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}') || echo "Cluster Install Failed"
#     cluster_type=""
#     if [ "$platform" = "AWS" ]; then
#         cluster_type=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.resourceTags[?(@.key=="red-hat-clustertype")].value}') || echo "Cluster Install Failed"
#     fi
#     if [ -z "$cluster_type" ]; then
#         cluster_type="self-managed"
#     fi

#     masters=0
#     infra=0
#     workers=0
#     all=0
#     master_type=""
#     infra_type=""
#     worker_type=""

#     for node in $(oc get nodes --ignore-not-found --no-headers -o custom-columns=:.metadata.name || true); do
#         labels=$(oc get node "$node" --no-headers -o jsonpath='{.metadata.labels}')
#         if [[ $labels == *"node-role.kubernetes.io/master"* ]]; then
#             masters=$((masters + 1))
#             master_type=$(oc get node "$node" -o jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
#             taints=$(oc get node "$node" -o jsonpath='{.spec.taints}')

#             if [[ $labels == *"node-role.kubernetes.io/worker"* && $taints == "" ]]; then
#                 workers=$((workers + 1))
#             fi
#         elif [[ $labels == *"node-role.kubernetes.io/infra"* ]]; then
#             infra=$((infra + 1))
#             infra_type=$(oc get node "$node" -o jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
#         elif [[ $labels == *"node-role.kubernetes.io/worker"* ]]; then
#             workers=$((workers + 1))
#             worker_type=$(oc get node "$node" -o jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
#         fi
#         all=$((all + 1))
#     done

# }

# get_ipsec_config(){
#     ipsec=false
#     ipsecMode="Disabled"
#     if result=$(oc get networks.operator.openshift.io cluster -o=jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig.mode}'); then
#         # If $result is empty, it is version older than 4.15
#         # We need to check a level above in the jsonpath
#         # If that level is not empty it means ipsec is enabled
#         if [[ -z $result ]]; then
#             if deprecatedresult=$(oc get networks.operator.openshift.io cluster -o=jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig}'); then
#                 if [[ ! -z $deprecatedresult ]]; then
#                     ipsec=true
#                     ipsecMode="Full"
#                 fi
#             fi
#         else
#             # No matter if enabled and then disabled or disabled by default,
#             # this field is always shows Disabled when no IPSec
#             if [[ ! $result == *"Disabled"* ]]; then
#                 ipsec=true
#                 ipsecMode=$result
#             fi
#         fi
#     fi
# }

# get_fips_config(){
#     fips=false
#     if result=$(oc get cm cluster-config-v1 -n kube-system -o json | jq -r '.data."install-config"' | grep 'fips: ' | cut -d' ' -f2); then
#         fips=$result
#     fi
# }

# get_ocp_virt_config(){
#     ocp_virt=false
#     if [[ `oc get pods -n openshift-cnv -l app.kubernetes.io/component=compute | wc -l` -gt 0 ]]; then
#         ocp_virt=true
#     fi
# }

# get_ocp_virt_version_config(){
#     ocp_virt_version=""
#     if result=$(kubectl get csv -n openshift-cnv -o jsonpath='{.items[0].spec.version}' 2> /dev/null); then
#         ocp_virt_version=$result
#     fi
# }

# get_ocp_virt_tuning_policy_config(){
#     ocp_virt_tuning_policy=""
#     if result=$(kubectl get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.spec.tuningPolicy}' 2> /dev/null); then
#         ocp_virt_tuning_policy=$result
#     fi
# }

# get_encryption_config(){
#     # Check the apiserver for the encryption config
#     # If encryption was never turned on, you won't find this config on the apiserver
#     encrypted=false
#     encryption=$(oc get apiserver -o=jsonpath='{.items[0].spec.encryption.type}' )
#     # Check for null or empty string
#     if [[ -n $encryption && $encryption != "null" ]]; then
#         # If the encryption has been Turned OFF at some point
#         # Then encryption type will be "identity"
#         # This means that it is not encrypted
#         if [[ $encryption != "identity" ]]; then
#             encrypted=true
#         fi
#     else
#         # Removing "identity" value of the encryption type
#         encryption=""
#     fi
# }

# get_publish_config(){
#     publish="External"
#     if result=$(oc get cm cluster-config-v1 -n kube-system -o json | jq -r '.data."install-config"' | grep 'publish' | cut -d' ' -f2 | xargs ); then
#         publish=$result
#     fi
# }

# get_architecture_config(){
#     compute_arch=""
#     if result=$(oc get cm cluster-config-v1 -n kube-system -o json | jq -r '.data."install-config"' | grep -A1 compute | grep architecture | cut -d' ' -f3 ); then
#         compute_arch=$result
#     fi

#     control_plane_arch=""
#     if result=$(oc get cm cluster-config-v1 -n kube-system -o json | jq -r '.data."install-config"' | grep -A1 controlPlane | grep architecture | cut -d' ' -f4 ); then
#         control_plane_arch=$result
#     fi
# }

# index_task(){
#     url=$1
#     uuid_dir=/tmp/$UUID
#     mkdir -p "$uuid_dir"

#     start_date_unix_timestamp=$(date "+%s" -d "${start_date}")
#     end_date_unix_timestamp=$(date "+%s" -d "${end_date}")
#     current_timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

#     # Create base JSON
#     base_json='{
#         "ciSystem":"'"$ci"'",
#         "uuid":"'"$UUID"'",
#         "releaseStream":"'"$RELEASE_STREAM"'",
#         "platform":"'"$platform"'",
#         "clusterType":"'"$cluster_type"'",
#         "benchmark":"'"$WORKLOAD"'",
#         "masterNodesCount":'"$masters"',
#         "workerNodesCount":'"$workers"',
#         "infraNodesCount":'"$infra"',
#         "masterNodesType":"'"$master_type"'",
#         "workerNodesType":"'"$worker_type"'",
#         "infraNodesType":"'"$infra_type"'",
#         "totalNodesCount":'"$all"',
#         "clusterName":"'"$cluster_name"'",
#         "ocpVersion":"'"$cluster_version"'",
#         "ocpVirt":"'"$ocp_virt"'",
#         "ocpVirtVersion":"'"$ocp_virt_version"'",
#         "ocpVirtTuningPolicy":"'"$ocp_virt_tuning_policy"'",
#         "networkType":"'"$network_type"'",
#         "buildTag":"'"$task_id"'",
#         "jobStatus":"'"$state"'",
#         "jobType":"'"$job_type"'",
#         "buildUrl":"'"$build_url"'",
#         "upstreamJob":"'"$job_id"'",
#         "upstreamJobBuild":"'"$job_run_id"'",
#         "executionDate":"'"$execution_date"'",
#         "jobDuration":"'"$duration"'",
#         "startDate":"'"$start_date"'",
#         "endDate":"'"$end_date"'",
#         "startDateUnixTimestamp":"'"$start_date_unix_timestamp"'",
#         "endDateUnixTimestamp":"'"$end_date_unix_timestamp"'",
#         "timestamp":"'"$current_timestamp"'",
#         "ipsec":"'"$ipsec"'",
#         "ipsecMode":"'"$ipsecMode"'",
#         "fips":"'"$fips"'",
#         "encrypted":"'"$encrypted"'",
#         "encryptionType":"'"$encryption"'",
#         "publish":"'"$publish"'",
#         "computeArch":"'"$compute_arch"'",
#         "controlPlaneArch":"'"$control_plane_arch"'"
#     }'

#     # Ensure ADDITIONAL_PARAMS is valid JSON
#     if [[ -n "$ADDITIONAL_PARAMS" ]]; then
#         if ! echo "$ADDITIONAL_PARAMS" | jq . >/dev/null 2>&1; then
#             echo "Error: ADDITIONAL_PARAMS is not valid JSON."
#             exit 1
#         fi
#     else
#         ADDITIONAL_PARAMS='{}' # Default to empty JSON if not set
#     fi

#     # Merge base_json with ADDITIONAL_PARAMS
#     merged_json=$(jq -n --argjson base "$base_json" --argjson extra "$ADDITIONAL_PARAMS" '$base + $extra')

#     # Save and send the merged JSON
#     echo "$merged_json" >> $uuid_dir/index_data.json
#     echo "$merged_json"
#     curl -sS --insecure -X POST -H "Content-Type:application/json" -H "Cache-Control:no-cache" -d "$merged_json" "$url"
# }

# set_duration(){
#     start_date="$1"
#     end_date="$2"
#     if [[ -z $start_date ]]; then
#         start_date=$end_date
#     fi

#     if [[ -z $start_date || -z $end_date ]]; then
#         duration=0
#     else
#         end_ts=$(date -u -d "$end_date" +"%s")
#         start_ts=$(date -u -d "$start_date" +"%s")
#         duration=$(( $end_ts - $start_ts ))
#     fi
# }


# index_tasks(){
#     if [[ -n $AIRFLOW_CTX_DAG_ID ]]; then
#         task_states=$(AIRFLOW__LOGGING__LOGGING_LEVEL=ERROR  airflow tasks states-for-dag-run $job_id $execution_date -o json)
#         task_json=$( echo $task_states | jq -c ".[] | select( .task_id == \"$TASK\")")
#         state=$(echo $task_json | jq -r '.state')
#         task_id=$(echo $task_json | jq -r '.task_id')

#         if [[ $task_id == "$AIRFLOW_CTX_TASK_ID" || $task_id == "cleanup" ]]; then
#             echo "Index Task doesn't index itself or cleanup step, skipping."
#         else
#             start_date=$(echo $task_json | jq -r '.start_date')
#             end_date=$(echo $task_json | jq -r '.end_date')
#             set_duration "$start_date" "$end_date"
#             encoded_execution_date=$(python3 -c "import urllib.parse; print(urllib.parse.quote(input()))" <<< "$execution_date")
#             build_url="${airflow_base_url}/task?dag_id=${job_id}&task_id=${task_id}&execution_date=${encoded_execution_date}"
#             index_task "$ES_SERVER/$ES_INDEX/_doc/$job_id%2F$job_run_id%2F$task_id%2F$UUID"
#         fi
#      elif [[ -n $PROW_JOB_ID ]]; then
#         task_id=$BUILD_ID
#         job_id=$JOB_NAME
#         job_run_id=$PROW_JOB_ID
#         state=$JOB_STATUS
#         if [[ "${JOB_TYPE}" == "presubmit" ]]; then
#             build_url="${prow_pr_base_url}/${PULL_NUMBER}/${job_id}/${task_id}"
#         else
#             build_url="${prow_base_url}/${job_id}/${task_id}"
#         fi
#         execution_date=$JOB_START
#         set_duration "$JOB_START" "$JOB_END"
#         index_task "$ES_SERVER/$ES_INDEX/_doc/$job_id%2F$job_run_id%2F$task_id%2F$UUID"
#     elif [[ -n $BUILD_ID ]]; then
#         task_id=$BUILD_ID
#         job_id=$JOB_BASE_NAME
#         state=$JOB_STATUS
#         execution_date=$JOB_START
#         set_duration "$JOB_START" "$JOB_END"
#         index_task "$ES_SERVER/$ES_INDEX/_doc/$job_id%2F$task_id%2F$UUID"
#     fi
# }

# # Defaults
# if [[ -z $PROW_JOB_ID && -z $AIRFLOW_CTX_DAG_ID && -z $BUILD_ID ]]; then
#     echo "Not a CI run. Skipping CI metrics to be indexed"
#     exit 0
# fi
# if [[ -z $ES_SERVER ]]; then
#   echo "Elastic server is not defined, please check"
#   exit 0
# fi
# if [[ -z $UUID ]]; then
#   echo "UUID is not present. UUID is a must for the indexing step"
#   exit 0
# fi

# ES_INDEX=perf_scale_ci

# invoke send to dashboad index.sh
export ES_SERVER="${ELK_SERVER}"
export BUILD_ID="${BUILD_ID}"
export UUID="${TEST_UUID}"
export BUILD_URL="${PROW_JOB_URL}"
export JOB_STATUS="$JOB_STATUS"
export JOB_START="$start_time"
export JOB_END="$end_time"
export WORKLOAD="quay-load-test"
export RELEASE_STREAM="${QUAY_OPERATOR_CHANNEL}"
export HITSIZE="${HITSIZE}"
export CONCURRENCY="${CONCURRENCY}"
export PUSH_PULL_NUMBERS="${PUSH_PULL_NUMBERS}"
export TEST_PHASES="${TEST_PHASES}"

echo "es server is: $ES_SERVER"


# setup
# get_ipsec_config
# get_fips_config
# get_ocp_virt_config
# get_ocp_virt_version_config
# get_ocp_virt_tuning_policy_config
# get_encryption_config
# get_publish_config
# get_architecture_config
# index_tasks
