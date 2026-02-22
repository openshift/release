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
LATEST_TAG=$(curl -s "https://api.github.com/repos/cloud-bulldozer/e2e-benchmarking/releases/latest" | jq -r '.tag_name');
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

EXTRA_FLAGS="${METRIC_PROFILES} --additional-worker-nodes ${ADDITIONAL_WORKER_NODES} --enable-autoscaler=${DEPLOY_AUTOSCALER}" 

export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

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

# OCPBUGS-70130: Start OVN annotation monitoring if requested
if [[ "$EXTRA_FLAGS" == *"--annotation-check=k8s.ovn.org/remote-zone-migrated"* ]]; then
  echo "$(date): Starting OCPBUGS-70130 OVN annotation monitoring"
  echo "Monitoring node readiness and k8s.ovn.org/remote-zone-migrated annotation"
  echo "This test validates the fix for rapid node scaling in OVN-Kubernetes"
  echo "Target: Adding $ADDITIONAL_WORKER_NODES workers to test annotation behavior"
  echo "========================================================================"
  
  # Track initial state
  INITIAL_READY_NODES=$(oc get nodes --no-headers | grep -c " Ready " || echo 0)
  echo "$(date): Initial ready nodes: $INITIAL_READY_NODES"
  
  # Start monitoring in background
  {
    while true; do
      TIMESTAMP=$(date)
      
      # Count total nodes
      TOTAL_NODES=$(oc get nodes --no-headers | wc -l)
      
      # Count ready nodes
      READY_NODES=$(oc get nodes --no-headers | grep -c " Ready " || echo 0)
      
      # Count not ready nodes
      NOT_READY_NODES=$(oc get nodes --no-headers | grep -c " NotReady " || echo 0)
      
      # Count nodes without the annotation
      NODES_WITHOUT_ANNOTATION=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' | grep -c "^[^ ]* $" || echo 0)
      
      # Count nodes with the annotation
      NODES_WITH_ANNOTATION=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' | grep -c "^[^ ]* [^ ]*$" || echo 0)
      
      echo "$TIMESTAMP: NODES: Total=$TOTAL_NODES Ready=$READY_NODES NotReady=$NOT_READY_NODES"
      echo "$TIMESTAMP: ANNOTATIONS: WithAnnotation=$NODES_WITH_ANNOTATION WithoutAnnotation=$NODES_WITHOUT_ANNOTATION"
      
      # Check for nodes stuck without annotation
      if [ $NODES_WITHOUT_ANNOTATION -gt 0 ] && [ $NOT_READY_NODES -gt 0 ]; then
        echo "$TIMESTAMP: WARNING: $NOT_READY_NODES nodes not ready, $NODES_WITHOUT_ANNOTATION missing remote-zone-migrated annotation"
        
        # List specific nodes without annotation that are not ready
        echo "$TIMESTAMP: Nodes without annotation:"
        oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' | while read node ready annotation; do
          if [[ "$ready" == "False" && "$annotation" == "" ]]; then
            echo "$TIMESTAMP:   $node (Ready=$ready, Annotation=missing)"
          fi
        done
      fi
      
      # Check if all nodes became ready suddenly
      if [ $READY_NODES -gt $((INITIAL_READY_NODES + 5)) ]; then
        READY_JUMP=$((READY_NODES - INITIAL_READY_NODES))
        if [ $READY_JUMP -gt 10 ]; then
          echo "$TIMESTAMP: ALERT: Large jump in ready nodes (+$READY_JUMP) - possible mass readiness event"
          echo "$TIMESTAMP: ANALYSIS: This indicates OCPBUGS-70130 fix is working - nodes becoming ready rapidly"
        fi
      fi
      
      # Report progress milestones
      PROGRESS_PCT=$(echo "scale=1; $READY_NODES * 100 / ($INITIAL_READY_NODES + $ADDITIONAL_WORKER_NODES)" | bc -l 2>/dev/null || echo "0")
      if [ $READY_NODES -gt $INITIAL_READY_NODES ]; then
        ADDED_WORKERS=$((READY_NODES - INITIAL_READY_NODES))
        echo "$TIMESTAMP: PROGRESS: Added $ADDED_WORKERS/$ADDITIONAL_WORKER_NODES workers (${PROGRESS_PCT}%)"
      fi
      
      # Exit monitoring if we've reached target nodes and all are ready
      TARGET_TOTAL=$((INITIAL_READY_NODES + ADDITIONAL_WORKER_NODES))
      if [ $TOTAL_NODES -ge $TARGET_TOTAL ] && [ $NOT_READY_NODES -eq 0 ]; then
        echo "$TIMESTAMP: SUCCESS: Reached target nodes ($TOTAL_NODES) and all are ready"
        break
      fi
      
      sleep 10
    done
    
    # Final analysis
    FINAL_TOTAL=$(oc get nodes --no-headers | wc -l)
    FINAL_READY=$(oc get nodes --no-headers | grep -c " Ready " || echo 0)
    FINAL_NOT_READY=$(oc get nodes --no-headers | grep -c " NotReady " || echo 0)
    FINAL_WITH_ANNOTATION=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' | grep -c "^[^ ]* [^ ]*$" || echo 0)
    FINAL_WITHOUT_ANNOTATION=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.annotations.k8s\.ovn\.org/remote-zone-migrated}{"\n"}{end}' | grep -c "^[^ ]* $" || echo 0)
    
    echo "========== FINAL OCPBUGS-70130 Test Results =========="
    echo "$(date): FINAL CLUSTER STATE:"
    echo "$(date):   Total Nodes: $FINAL_TOTAL"
    echo "$(date):   Ready Nodes: $FINAL_READY" 
    echo "$(date):   NotReady Nodes: $FINAL_NOT_READY"
    echo "$(date): FINAL ANNOTATION STATE:"
    echo "$(date):   With remote-zone-migrated: $FINAL_WITH_ANNOTATION"
    echo "$(date):   Without annotation: $FINAL_WITHOUT_ANNOTATION"
    echo "$(date): TEST SCOPE: Scaled from $INITIAL_READY_NODES to $FINAL_TOTAL nodes (+$((FINAL_TOTAL - INITIAL_READY_NODES)) workers)"
    
    # Test assessment with detailed analysis
    if [ $FINAL_NOT_READY -eq 0 ] && [ $FINAL_TOTAL -ge $TARGET_TOTAL ]; then
      echo "$(date): ✅ SUCCESS: All $FINAL_TOTAL nodes are Ready - OCPBUGS-70130 fix is working!"
      echo "$(date): ✅ ANALYSIS: Rapid scaling to $FINAL_TOTAL nodes completed without node readiness issues"
    else
      echo "$(date): ❌ WARNING: $FINAL_NOT_READY nodes still NotReady out of $FINAL_TOTAL total"
      echo "$(date): ❌ ANALYSIS: Potential scaling issue detected - investigate further"
    fi
    
    # Annotation analysis for Ricardo
    if [ $FINAL_WITHOUT_ANNOTATION -eq $FINAL_TOTAL ]; then
      echo "$(date): 📝 ANNOTATION ANALYSIS: No nodes have remote-zone-migrated annotation"
      echo "$(date): 📝 EXPECTED BEHAVIOR: Post-fix, annotations should be cleaned up after successful migration"
    elif [ $FINAL_WITHOUT_ANNOTATION -gt 0 ]; then
      echo "$(date): 📝 ANNOTATION ANALYSIS: Mixed state - $FINAL_WITHOUT_ANNOTATION missing, $FINAL_WITH_ANNOTATION with annotation"
      echo "$(date): 📝 INVESTIGATION: Check if nodes are in transition or if cleanup is incomplete"
    else
      echo "$(date): 📝 ANNOTATION ANALYSIS: All nodes have remote-zone-migrated annotation"
      echo "$(date): 📝 INVESTIGATION: Verify if this is expected behavior for your OpenShift version"
    fi
  } > ${SHARED_DIR}/ocpbugs-70130-monitoring.log 2>&1 &
  
  MONITOR_PID=$!
  echo "$(date): Started OCPBUGS-70130 monitoring (PID: $MONITOR_PID)"
  echo "$MONITOR_PID" > ${SHARED_DIR}/ocpbugs-70130-monitor-pid
fi

# Hardcoding workers-scale ES_INDEX as its only used by OCP perfscale team for now.
ES_INDEX="workers-scale-results" ./run.sh

# OCPBUGS-70130: Stop monitoring and show results
if [[ "$EXTRA_FLAGS" == *"--annotation-check=k8s.ovn.org/remote-zone-migrated"* ]]; then
  echo "$(date): Stopping OCPBUGS-70130 monitoring and collecting results"
  
  # Stop monitoring process if still running
  if [ -f ${SHARED_DIR}/ocpbugs-70130-monitor-pid ]; then
    MONITOR_PID=$(cat ${SHARED_DIR}/ocpbugs-70130-monitor-pid)
    if kill -0 $MONITOR_PID 2>/dev/null; then
      kill $MONITOR_PID
      echo "$(date): Stopped monitoring process (PID: $MONITOR_PID)"
    fi
  fi
  
  # Show monitoring results
  if [ -f ${SHARED_DIR}/ocpbugs-70130-monitoring.log ]; then
    echo "========== OCPBUGS-70130 Monitoring Results =========="
    tail -100 ${SHARED_DIR}/ocpbugs-70130-monitoring.log
  fi
fi
