#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python --version
pushd /tmp
python -m virtualenv ./venv_qe
source ./venv_qe/bin/activate

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/workers-scale

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

ROSA_SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
ROSA_SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${LEASED_RESOURCE}"
else
  echo "Did not find compatible cloud provider cluster_profile"
fi

if [[ -n "${ROSA_SSO_CLIENT_ID}" && -n "${ROSA_SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${ROSA_LOGIN_ENV} with SSO credentials"
  rosa login --env "${ROSA_LOGIN_ENV}" --client-id "${ROSA_SSO_CLIENT_ID}" --client-secret "${ROSA_SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${ROSA_LOGIN_ENV} with offline token"
  rosa login --env "${ROSA_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
fi

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

run_scale() {
  local worker_count="$1"
  EXTRA_FLAGS="${METRIC_PROFILES} --additional-worker-nodes ${worker_count} --enable-autoscaler=${DEPLOY_AUTOSCALER}"

  if [ "$DEPLOY_AUTOSCALER" = "false" ] && [ -f "${SHARED_DIR}/workers_scale_event_epoch.txt" ] && [ -f "${SHARED_DIR}/workers_scale_end_epoch.txt" ]; then
    START_TIME=$(cat "${SHARED_DIR}/workers_scale_event_epoch.txt")
    export START_TIME
    END_TIME=$(cat "${SHARED_DIR}/workers_scale_end_epoch.txt")
    export END_TIME
    EXTRA_FLAGS="${METRIC_PROFILES} --scale-event-epoch ${START_TIME}"
    rm -f "${SHARED_DIR}/workers_scale_event_epoch.txt"
    rm -f "${SHARED_DIR}/workers_scale_end_epoch.txt"
  fi

  export EXTRA_FLAGS
  ES_INDEX="workers-scale-results" ./run.sh
}

wait_for_ipsec_tunnels() {
  set +x
  local expected_tunnels
  expected_tunnels=$(( $(oc get nodes --no-headers | wc -l) - 1 ))
  echo "Expecting each ovn-ipsec-host pod to report $expected_tunnels tunnels Up"

  declare -A pod_node_map
  while IFS= read -r line; do
    local pod node
    pod=$(echo "$line" | awk '{print $1}')
    node=$(echo "$line" | awk '{print $7}')
    pod_node_map["$pod"]="$node"
  done < <(oc get pods -n openshift-ovn-kubernetes -l app=ovn-ipsec -o wide --no-headers)

  declare -A wait_counts
  local status_file="${ARTIFACT_DIR}/ipsec-tunnel-status.txt"
  local deadline all_up
  all_up=false

  echo "Waiting 120s for ipsec daemonset pods to initialize..."
  sleep 120

  deadline=$(( $(date +%s) + ${IPSEC_WAIT_TIMEOUT:-600} ))
  while [[ $(date +%s) -lt $deadline ]]; do
    all_up=true
    : > "$status_file"
    echo "=== IPsec Tunnel Status ($(date -u)) ===" >> "$status_file"

    for pod in "${!pod_node_map[@]}"; do
      local node
      node="${pod_node_map[$pod]}"
      if oc logs "$pod" -n openshift-ovn-kubernetes -c ovn-ipsec 2>/dev/null | grep -q "Connections for all(${expected_tunnels}) configured tunnels are Up"; then
        echo "UP    | pod=$pod | node=$node" >> "$status_file"
        unset "wait_counts[$node]" 2>/dev/null || true
      else
        wait_counts[$node]=$(( ${wait_counts[$node]:-0} + 1 ))
        echo "WAIT  | pod=$pod | node=$node | attempts=${wait_counts[$node]}" >> "$status_file"
        all_up=false
      fi
    done

    cat "$status_file"

    if $all_up; then
      break
    fi

    echo "Waiting 30s before next check..."
    sleep 30
  done

  if $all_up; then
    echo "######################################################################################"
    echo "#          All ovn-ipsec-host pods report all tunnels are Up!                        #"
    echo "######################################################################################"
  else
    echo "######################################################################################"
    echo "#   TIMEOUT: Not all ovn-ipsec-host pods reported tunnels Up within timeout          #"
    echo "######################################################################################"
    echo "" >> "$status_file"
    echo "=== Final pod logs (last 10 lines each) ===" >> "$status_file"
    for pod in "${!pod_node_map[@]}"; do
      local node
      node="${pod_node_map[$pod]}"
      echo "--- $pod (node=$node) ---" >> "$status_file"
      oc logs "$pod" -n openshift-ovn-kubernetes --tail=10 2>/dev/null >> "$status_file" || true
    done
  fi
  set -x
}

run_scale "${ADDITIONAL_WORKER_NODES}"
if [[ "${JOB_NAME}" == *ipsec* ]]; then
  wait_for_ipsec_tunnels
fi
