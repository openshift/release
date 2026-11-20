#!/bin/bash -e

set -e

if [[ -n ${QPS_LIST:-} ]]; then
  exec bash "$(dirname "${BASH_SOURCE[0]}")/sweep.sh" "$@"
fi

ES_SERVER=${ES_SERVER:-}
LOG_LEVEL=${LOG_LEVEL:-info}
if [ "$KUBE_BURNER_VERSION" = "default" ]; then
    unset KUBE_BURNER_VERSION
fi
KUBE_BURNER_VERSION=${KUBE_BURNER_VERSION:-1.12.6}
OS=$(uname -s)
HARDWARE=$(uname -m)
WORKLOAD=${WORKLOAD:?}
QPS=${QPS:-20}
BURST=${BURST:-20}
GC=${GC:-true}
EXTRA_FLAGS=${EXTRA_FLAGS:-}
UUID=${UUID:-$(uuidgen)}
KUBE_DIR=${KUBE_DIR:-/tmp}
ES_INDEX=${ES_INDEX:-ripsaw-kube-burner}

download_binary(){
  if [[ -z ${KUBE_BURNER_URL} ]]; then
    KUBE_BURNER_URL="https://github.com/kube-burner/kube-burner-ocp/releases/download/v${KUBE_BURNER_VERSION}/kube-burner-ocp-V${KUBE_BURNER_VERSION}-${OS}-${HARDWARE}.tar.gz"
  fi
  curl --fail --retry 8 --retry-all-errors -sS -L "${KUBE_BURNER_URL}" | tar -xzC "${KUBE_DIR}/" kube-burner-ocp
}

hypershift(){
  echo "HyperShift detected"

  # Get hosted cluster ID and name
  HC_ID=$(oc get infrastructure cluster -o go-template --template='{{.status.infrastructureName}}')
  HC_PLATFORM=$(oc get infrastructure cluster -o go-template --template='{{.status.platform}}'| awk '{print tolower($0)}')

  if [[ $HC_PLATFORM == "aws" ]]; then
    echo "Detected ${HC_PLATFORM} environment..."

    MC_NAME=$(oc get --kubeconfig=${MC_KUBECONFIG} infrastructure.config.openshift.io cluster -o json 2>/dev/null | jq -r .status.infrastructureName)
    HC_NAME=$(oc get infrastructure cluster -o go-template --template='{{range .status.platformStatus.aws.resourceTags}}{{if eq .key "api.openshift.com/name" }}{{.value}}{{end}}{{end}}')
    # Hosted control-plane namespace is composed by the cluster ID plus the cluster name
    HCP_NAMESPACE=${HC_ID}-${HC_NAME}
    QUERY="sum(cluster:nodes_roles{label_hypershift_openshift_io_control_plane=\"true\",label_hypershift_openshift_io_request_serving_component!=\"true\"})by(node)"

    echo "Creating OBO route on MC"
    oc --kubeconfig=${MC_KUBECONFIG} apply -f obo-route.yml
    echo "Fetching OBO endpoint"
    MC_OBO=http://$(oc --kubeconfig=${MC_KUBECONFIG} get route -n openshift-observability-operator prometheus-hypershift -o jsonpath="{.spec.host}")
    MC_PROMETHEUS=https://$(oc --kubeconfig=${MC_KUBECONFIG} get route -n openshift-monitoring prometheus-k8s -o jsonpath="{.spec.host}")
    set +x
    MC_PROMETHEUS_TOKEN=$(oc --kubeconfig=${MC_KUBECONFIG} create token -n openshift-monitoring prometheus-k8s --duration=24h)
    set -x
    HC_PRODUCT="rosa"
  else
    echo "Detected ${HC_PLATFORM} environment..."

    if [ -z "${MC_NAME}" ]; then
      MC_NAME=$(kubectl config view -o jsonpath='{.clusters[].name}' --kubeconfig="${MC_KUBECONFIG}")
    fi
    HC_NAME=$(oc get infrastructure cluster -o go-template --template='{{.status.etcdDiscoveryDomain}}' | awk -F. '{print$2}')
    HCP_NAMESPACE=${HC_NAME}
    QUERY="sum(node_memory_MemTotal_bytes{cluster=\"$MC_NAME\",instance=~\".*user.*\"})by(instance)"

    if [[ -z ${AKS_PROM} ]] || [[ -z ${AZURE_PROM} ]] ; then
      echo "Azure/AKS prometheus inputs are missing, exiting.."
      exit 1
    elif [[ -z ${AZURE_PROM_TOKEN} ]]; then
      if [[ -z ${AZ_CLIENT_SECRET} ]] || [[ -z ${AZ_CLIENT_ID} ]] ; then
        echo "Azure/AKS prometheus token is missing and cannot be calculated, exiting.."
	exit 1
      else
        set +x
	AZURE_PROM_TOKEN=$(curl --request POST 'https://login.microsoftonline.com/64dc69e4-d083-49fc-9569-ebece1dd1408/oauth2/v2.0/token' --header 'Content-Type: application/x-www-form-urlencoded' --data-urlencode "client_id=${AZ_CLIENT_ID}" --data-urlencode 'grant_type=client_credentials' --data-urlencode "client_secret=${AZ_CLIENT_SECRET}" --data-urlencode 'scope=https://prometheus.monitor.azure.com/.default' | jq -r '.access_token')
        set -x
      fi
    fi

    MC_OBO=$AKS_PROM
    MC_PROMETHEUS=$AZURE_PROM
    set +x
    MC_PROMETHEUS_TOKEN=$AZURE_PROM_TOKEN
    set -x
    HC_PRODUCT="aro"
  fi

  echo "Indexing Management cluster stats"
  METADATA=$(cat << EOF
{
"uuid": "${UUID}",
"workload": "${WORKLOAD}",
"mgmtClusterName": "${MC_NAME}",
"hostedClusterName": "${HC_NAME}",
"timestamp": "$(date +%s%3N)"
}
EOF
)

  HOSTED_PROMETHEUS=https://$(oc get route -n openshift-monitoring prometheus-k8s -o jsonpath="{.spec.host}")

  set +x
  # Retry until HOSTED_PROMETHEUS_TOKEN is retrieved
  until HOSTED_PROMETHEUS_TOKEN=$(oc create token -n openshift-monitoring prometheus-k8s --duration=24h 2>/dev/null) && [[ -n "$HOSTED_PROMETHEUS_TOKEN" ]]; do
    echo "Waiting for HOSTED_PROMETHEUS_TOKEN..."
    sleep 30
  done
  set -x

  echo "Get all management worker nodes, excludes infra, obo, workload"
  Q_NODES=""
  set +x
  Q_STDOUT=$(curl -H "Authorization: Bearer ${MC_PROMETHEUS_TOKEN}" -k --silent --globoff ${MC_PROMETHEUS}/api/v1/query?query=${QUERY}&time='$(date +"%s")' 2>/dev/null)
  set -x
  for n in $(echo "$Q_STDOUT" | jq -r ".data.result[].metric.$([ \"$HC_PLATFORM\" = \"aws\" ] && echo node || echo instance)"); do
    if [[ ${Q_NODES} == "" ]]; then
      Q_NODES=${n}
    else
      Q_NODES=${Q_NODES}"|"${n};
    fi
  done
  MGMT_WORKER_NODES=${Q_NODES}

  echo "Exporting required vars"
  cat << EOF
MC_NAME: ${MC_NAME}
MC_OBO: ${MC_OBO}
MC_PROMETHEUS: ${MC_PROMETHEUS}
MC_PROMETHEUS_TOKEN: <truncated>
HOSTED_PROMETHEUS: ${HOSTED_PROMETHEUS}
HOSTED_PROMETHEUS_TOKEN: <truncated>
HCP_NAMESPACE: ${HCP_NAMESPACE}
MGMT_WORKER_NODES: ${MGMT_WORKER_NODES}
HC_PRODUCT: ${HC_PRODUCT}
HC_PLATFORM: ${HC_PLATFORM}
EOF

  if [[ ${WORKLOAD} =~ "index" ]]; then
    export elapsed=${ELAPSED:-20m}
  fi
  
  set +x
  export MC_OBO MC_PROMETHEUS MC_PROMETHEUS_TOKEN HOSTED_PROMETHEUS HOSTED_PROMETHEUS_TOKEN HCP_NAMESPACE MGMT_WORKER_NODES HC_PRODUCT MC_NAME HC_PLATFORM
  set -x

}

download_binary
if [[ ${WORKLOAD} =~ "index" ]]; then
  cmd="${KUBE_DIR}/kube-burner-ocp index --uuid=${UUID} --start=$START_TIME --end=$((END_TIME+600)) --log-level ${LOG_LEVEL}"
  JOB_START=$(date -u -d "@$START_TIME" +"%Y-%m-%dT%H:%M:%SZ")
  JOB_END=$(date -u -d "@$((END_TIME + 600))" +"%Y-%m-%dT%H:%M:%SZ")
  PPROF=false # pporf is not supported for index job, it is not required for index executions.
else
  cmd="${KUBE_DIR}/kube-burner-ocp ${WORKLOAD} --log-level=${LOG_LEVEL} --qps=${QPS} --burst=${BURST} --gc=${GC} --uuid ${UUID}"
fi
cmd+=" ${EXTRA_FLAGS}"
if [[ ${WORKLOAD} =~ "cluster-density" || ${WORKLOAD} =~ "udn-density-pods" || ${WORKLOAD} =~ "cudn-density" || ${WORKLOAD} =~ "rds-core" || ${WORKLOAD} =~ "network-policy" || ${WORKLOAD} =~ "evpn" || ${WORKLOAD} =~ ^(crd-scale|pvc-density|olm|udn-bgp)$ ]]; then
  ITERATIONS=${ITERATIONS:?}
  cmd+=" --iterations=${ITERATIONS}"
fi
if [[ ${WORKLOAD} =~ "kube-burner-ai" ]]; then
  WORKLOAD="cluster-density"
  numbers=(100 150 200 250 300 350 400 450 500)
  array_length=${#numbers[@]}
  random_index=$(( $RANDOM % array_length ))
  ITERATIONS=${numbers[$random_index]}

  cmd+=" --iterations=${ITERATIONS}"
fi
if [[ ${WORKLOAD} =~ "egressip" ]]; then
  source ./egressip.sh
  if [[ -v AWS_ACCESS_KEY_ID && -n $AWS_ACCESS_KEY_ID ]]; then
    prep_aws
    get_egressip_external_server
  fi
  ITERATIONS=${ITERATIONS:?}
  cmd+=" --iterations=${ITERATIONS} --external-server-ip=${EGRESSIP_EXTERNAL_SERVER_IP}"
fi

# if ES_SERVER is specified and for hypershift clusters
if [[ -n ${MC_KUBECONFIG} ]] && [[ -n ${ES_SERVER} ]]; then
  cmd+=" --metrics-endpoint=metrics-endpoint.yml"
  hypershift
  curl -k -sS -X POST -H "Content-type: application/json" ${ES_SERVER}/${ES_INDEX}/_doc -d "${METADATA}" -o /dev/null 2>/dev/null || echo "WARNING: Failed to index metadata to ES"
# for non-hypershift cluster
elif [[ -n ${ES_SERVER} ]]; then
  cmd+=" --es-server=${ES_SERVER} --es-index=${ES_INDEX}"
else
  echo "ES_SERVER is not set, not indexing the results"
fi

# Capture the exit code of the run, but don't exit the script if it fails.
set +e

redacted_cmd=${cmd}
if [[ -n ${ES_SERVER} ]]; then
  redacted_cmd=${redacted_cmd//"${ES_SERVER}"/<redacted-es-server>}
fi
if [[ -n ${PROMETHEUS_TOKEN:-} ]]; then
  redacted_cmd=${redacted_cmd//"${PROMETHEUS_TOKEN}"/<redacted-prometheus-token>}
fi
echo "${redacted_cmd}"
JOB_START=${JOB_START:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")};
$cmd
exit_code=$?
JOB_END=${JOB_END:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")};
if [ $exit_code -eq 0 ]; then
  JOB_STATUS="success"
else
  JOB_STATUS="failure"
fi

KUBE_BURNER_WORKLOAD_CONFIG='{}'
if [[ -n ${ES_SERVER} ]]; then
  # Just pick the value of the field workloadFlags from the first jobSummary entry
  WORKLOAD_FLAGS=$(curl -sS --insecure "${ES_SERVER}/${ES_INDEX}/_search" \
    -H "Content-Type: application/json" \
    -d '{"size":1,"query":{"bool":{"must":[{"term":{"uuid.keyword":"'"${UUID}"'"}},{"term":{"metricName.keyword":"jobSummary"}}]}}}'  2>/dev/null \
    | jq -r '.hits.hits[0]._source.workloadFlags // empty')
  if [[ -n ${WORKLOAD_FLAGS} ]]; then
    KUBE_BURNER_WORKLOAD_CONFIG=$(jq -n --argjson wf "$WORKLOAD_FLAGS" '{"kbCfg": $wf}')
  fi
fi

env JOB_START="$JOB_START" JOB_END="$JOB_END" JOB_STATUS="$JOB_STATUS" UUID="$UUID" WORKLOAD="$WORKLOAD" ES_SERVER="$ES_SERVER" KUBE_BURNER_WORKLOAD_CONFIG="$KUBE_BURNER_WORKLOAD_CONFIG" ../../utils/index.sh

if [[ ${WORKLOAD} =~ "egressip" ]]; then
    cleanup_egressip_external_server
fi
exit $exit_code
