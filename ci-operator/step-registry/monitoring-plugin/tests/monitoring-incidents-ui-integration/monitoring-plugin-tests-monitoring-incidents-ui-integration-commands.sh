#!/bin/bash
set -o nounset
set -o pipefail

# This script is designed to run as a step in Prow CI (OpenShift CI) jobs.
# We intentionally use 'exit 0' instead of 'exit 1' for failures to prevent
# blocking subsequent test steps in the CI pipeline. When a step exits with
# a non-zero code, the job stops and doesn't proceed to run subsequent steps.
# Since we're adding multiple test steps for different components, we want
# all steps to run regardless of individual step failures. Test failures
# can still be identified and analyzed through junit reports which are
# stored in the artifact directory and job status. A final step can be added 
# to parse the junit reports and fail the job if any tests fail.

# List of variables to check.
vars=(
  CYPRESS_SKIP_COO_INSTALL
  CYPRESS_COO_UI_INSTALL
  CYPRESS_KONFLUX_COO_BUNDLE_IMAGE
  CYPRESS_CUSTOM_COO_BUNDLE_IMAGE
  CYPRESS_MCP_CONSOLE_IMAGE
  CYPRESS_MP_IMAGE
  CYPRESS_FBC_STAGE_COO_IMAGE
  CYPRESS_COO_NAMESPACE
  CYPRESS_SESSION
  CYPRESS_TIMEZONE
  CYPRESS_MOCK_NEW_METRICS
)

# Loop through each variable.
for var in "${vars[@]}"; do
  if [[ -z "${!var}" ]]; then
    unset "$var"
    echo "Unset variable: $var"
  else
    echo "$var is set to '${!var}'"
  fi
done

# Read kubeadmin password from file
if [[ -z "${KUBEADMIN_PASSWORD_FILE:-}" ]]; then
  echo "Error: KUBEADMIN_PASSWORD_FILE variable is not set"
  exit 0
fi

if [[ ! -f "${KUBEADMIN_PASSWORD_FILE}" ]]; then
  echo "Error: Kubeadmin password file ${KUBEADMIN_PASSWORD_FILE} does not exist"
  exit 0
fi

kubeadmin_password=$(cat "${KUBEADMIN_PASSWORD_FILE}")
echo "Successfully read kubeadmin password from ${KUBEADMIN_PASSWORD_FILE}"

oc label namespace ${CYPRESS_COO_NAMESPACE} openshift.io/cluster-monitoring="true"
echo "Labeled namespace ${CYPRESS_COO_NAMESPACE} with openshift.io/cluster-monitoring=true"

# Set proxy vars.
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

## skip all tests when console is not installed.
if ! (oc get clusteroperator console --kubeconfig=${KUBECONFIG}) ; then
  echo "console is not installed, skipping all console tests."
  exit 0
fi

# Function to monitor memory usage in the background
function monitorMemory {
  local memory_log="${ARTIFACT_DIR}/memory-usage.log"
  local oom_log="${ARTIFACT_DIR}/oom-events.log"
  local interval=5  # Log every 5 seconds
  
  echo "Starting memory monitoring (logging every ${interval}s to ${memory_log})"
  echo "=== Memory Monitoring Started at $(date) ===" > "${memory_log}"
  echo "=== OOM Events Monitoring Started at $(date) ===" > "${oom_log}"
  
  # Capture initial dmesg state to detect new OOM events
  dmesg -T > "${ARTIFACT_DIR}/dmesg-initial.log" 2>&1 || echo "dmesg not available" > "${ARTIFACT_DIR}/dmesg-initial.log"
  
  while true; do
    echo "--- $(date) ---" >> "${memory_log}"
    free -h >> "${memory_log}" 2>&1
    echo "" >> "${memory_log}"
    echo "Memory details:" >> "${memory_log}"
    cat /proc/meminfo | grep -E "MemTotal|MemFree|MemAvailable|Cached|SwapTotal|SwapFree" >> "${memory_log}" 2>&1
    echo "" >> "${memory_log}"
    echo "Top 10 memory consuming processes:" >> "${memory_log}"
    ps aux --sort=-%mem | head -n 11 >> "${memory_log}" 2>&1
    echo "" >> "${memory_log}"
    
    # Check for OOM events in dmesg
    if dmesg -T 2>/dev/null | grep -i "out of memory\|oom-kill\|killed process" | tail -20 >> "${oom_log}" 2>&1; then
      echo "$(date): OOM event detected!" >> "${memory_log}"
    fi
    
    sleep "${interval}"
  done
}

# Function to copy artifacts to the artifact directory after test run.
function copyArtifacts {
  echo "=== Cleanup and Final Memory State ==="
  
  # Capture final memory state
  echo "Final memory state:" > "${ARTIFACT_DIR}/memory-final.log"
  free -h >> "${ARTIFACT_DIR}/memory-final.log" 2>&1
  echo "" >> "${ARTIFACT_DIR}/memory-final.log"
  df -h >> "${ARTIFACT_DIR}/memory-final.log" 2>&1
  
  # Capture final dmesg to check for OOM kills
  echo "Capturing final dmesg for OOM analysis..."
  dmesg -T > "${ARTIFACT_DIR}/dmesg-final.log" 2>&1 || echo "dmesg not available" > "${ARTIFACT_DIR}/dmesg-final.log"
  dmesg -T 2>/dev/null | grep -i "out of memory\|oom-kill\|killed process" > "${ARTIFACT_DIR}/oom-summary.log" 2>&1 || echo "No OOM events found in dmesg" > "${ARTIFACT_DIR}/oom-summary.log"
  
  # Stop memory monitoring if it's running
  if [ ! -z "${MEMORY_MONITOR_PID:-}" ]; then
    echo "Stopping memory monitor (PID: ${MEMORY_MONITOR_PID})"
    kill "${MEMORY_MONITOR_PID}" 2>/dev/null || true
    wait "${MEMORY_MONITOR_PID}" 2>/dev/null || true
  fi
  
  if [ -d "/tmp/monitoring-plugin/web/cypress/screenshots/" ]; then
    cp -r /tmp/monitoring-plugin/web/cypress/screenshots/ "${ARTIFACT_DIR}/screenshots"
    echo "Screenshots copied successfully."
  else
    echo "Directory screenshots does not exist. Nothing to copy."
  fi
  if [ -d "/tmp/monitoring-plugin/web/cypress/videos/" ]; then
    cp -r /tmp/monitoring-plugin/web/cypress/videos/ "${ARTIFACT_DIR}/videos"
    echo "Videos copied successfully."
  else
    echo "Directory videos does not exist. Nothing to copy."
  fi
  if [ -d "/tmp/monitoring-plugin/web/cypress/logs/" ]; then
    cp -r /tmp/monitoring-plugin/web/cypress/logs/ "${ARTIFACT_DIR}/console-logs"
    echo "Console logs copied successfully."
  else
    echo "Directory cypress/logs does not exist. Nothing to copy."
  fi
  
  echo "Artifacts and memory logs collected."
}

# Function to verify UIPlugin status
# Args: $1 - stage label (e.g., "before tests", "after tests")
verify_uiplugin_status() {
  local stage="$1"
  echo ""
  echo "=== Verifying UIPlugin Status ${stage} ==="
  if oc get uiplugin monitoring &>/dev/null; then
    echo "UIPlugin 'monitoring' found"
    if [ "$stage" = "before tests" ]; then
      oc get uiplugin monitoring -o yaml
    fi
    
    echo ""
    echo "Checking UIPlugin Reconciled condition:"
    RECONCILED=$(oc get uiplugin monitoring -o jsonpath='{.status.conditions[?(@.type=="Reconciled")].status}' 2>/dev/null)
    if [ -n "$RECONCILED" ]; then
      echo "Reconciled status: $RECONCILED"
      if [ "$RECONCILED" = "True" ]; then
        echo "✓ UIPlugin is reconciled"
      else
        echo "✗ UIPlugin is NOT reconciled"
        if [ "$stage" = "before tests" ]; then
          oc get uiplugin monitoring -o jsonpath='{.status.conditions[?(@.type=="Reconciled")]}'
          echo ""
        fi
      fi
    else
      echo "✗ Reconciled condition not found"
    fi
    
    echo ""
    echo "Checking UIPlugin Available condition:"
    AVAILABLE=$(oc get uiplugin monitoring -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
    if [ -n "$AVAILABLE" ]; then
      echo "Available status: $AVAILABLE"
      if [ "$AVAILABLE" = "True" ]; then
        echo "✓ UIPlugin is available"
      else
        echo "✗ UIPlugin is NOT available"
        if [ "$stage" = "before tests" ]; then
          oc get uiplugin monitoring -o jsonpath='{.status.conditions[?(@.type=="Available")]}'
          echo ""
        fi
      fi
    else
      echo "✗ Available condition not found"
    fi
  else
    echo "✗ UIPlugin 'monitoring' not found ${stage}"
    if [ "$stage" = "before tests" ]; then
      echo "Listing all UIPlugins:"
      oc get uiplugin -A || echo "No UIPlugins found"
    fi
  fi
}

# Function to verify metrics exposure
# Args: $1 - stage label (e.g., "before tests", "after tests")
verify_metrics_exposure() {
  local stage="$1"
  local is_detailed="false"
  [ "$stage" = "after tests" ] && is_detailed="true"
  
  echo ""
  echo "=== Verifying Metrics Exposure ${stage} ==="
  PROM_POD=$(oc get pods -n openshift-monitoring -l app.kubernetes.io/name=prometheus -o name 2>/dev/null | head -1 | sed 's#pod/##')
  if [ -n "$PROM_POD" ]; then
    echo "Found Prometheus pod in openshift-monitoring: $PROM_POD"
    
    echo ""
    echo "1. Querying cluster_health_components metric ${stage}:"
    RESULT=$(oc exec -n openshift-monitoring "$PROM_POD" -c prometheus -- curl -s "http://localhost:9090/api/v1/query?query=cluster_health_components" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$RESULT" ]; then
      echo "$RESULT" | jq '.' || echo "$RESULT"
      
      STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null)
      RESULT_TYPE=$(echo "$RESULT" | jq -r '.data.resultType' 2>/dev/null)
      RESULT_COUNT=$(echo "$RESULT" | jq -r '.data.result | length' 2>/dev/null)
      
      echo ""
      echo "Verification:"
      echo "  Status: $STATUS $([ "$STATUS" = "success" ] && echo "✓" || echo "✗")"
      echo "  ResultType: $RESULT_TYPE $([ "$RESULT_TYPE" = "vector" ] && echo "✓" || echo "✗")"
      echo "  Number of results: $RESULT_COUNT $([ "$RESULT_COUNT" -gt 0 ] && echo "✓" || echo "✗ (no results found)")"
    else
      echo "✗ Failed to query cluster_health_components metric ${stage}"
    fi
    
    echo ""
    echo "2. Querying cluster_health_components with non-empty component ${stage}:"
    RESULT_FILTERED=$(oc exec -n openshift-monitoring "$PROM_POD" -c prometheus -- curl -s -G "http://localhost:9090/api/v1/query" --data-urlencode 'query=cluster_health_components{component!=""}' 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$RESULT_FILTERED" ]; then
      echo "$RESULT_FILTERED" | jq '.' || echo "$RESULT_FILTERED"
      
      FILTERED_COUNT=$(echo "$RESULT_FILTERED" | jq -r '.data.result | length' 2>/dev/null)
      echo ""
      echo "  Components with data: $FILTERED_COUNT $([ "$FILTERED_COUNT" -gt 0 ] && echo "✓" || echo "✗")"
      
      # Show component names if available and in detailed mode
      if [ "$is_detailed" = "true" ] && [ "$FILTERED_COUNT" -gt 0 ]; then
        echo ""
        echo "  Component names found:"
        echo "$RESULT_FILTERED" | jq -r '.data.result[].metric.component' 2>/dev/null | sort | uniq | while read comp; do
          echo "    - $comp"
        done
      fi
    else
      echo "✗ Failed to query filtered cluster_health_components metric ${stage}"
    fi
    
    echo ""
    echo "3. Querying cluster_health_components_map metric ${stage} (CRITICAL):"
    RESULT_MAP=$(oc exec -n openshift-monitoring "$PROM_POD" -c prometheus -- curl -s "http://localhost:9090/api/v1/query?query=cluster_health_components_map" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$RESULT_MAP" ]; then
      echo "$RESULT_MAP" | jq '.' || echo "$RESULT_MAP"
      
      MAP_STATUS=$(echo "$RESULT_MAP" | jq -r '.status' 2>/dev/null)
      MAP_COUNT=$(echo "$RESULT_MAP" | jq -r '.data.result | length' 2>/dev/null)
      
      echo ""
      echo "Verification:"
      echo "  Status: $MAP_STATUS $([ "$MAP_STATUS" = "success" ] && echo "✓" || echo "✗")"
      echo "  Number of alert-to-component mappings: $MAP_COUNT $([ "$MAP_COUNT" -gt 0 ] && echo "✓" || echo "✗ (no mappings found)")"
      
      # Show detailed info if in detailed mode and mappings exist
      if [ "$is_detailed" = "true" ]; then
        if [ "$MAP_COUNT" -gt 0 ]; then
          echo ""
          echo "  Sample alert-to-component mappings (first 10):"
          echo "$RESULT_MAP" | jq -r '.data.result[0:10][] | "    Alert: \(.metric.alert) -> Component: \(.metric.component)"' 2>/dev/null || echo "    Failed to parse mappings"
          
          echo ""
          echo "  Unique components in mappings:"
          echo "$RESULT_MAP" | jq -r '.data.result[].metric.component' 2>/dev/null | sort | uniq -c | while read count comp; do
            echo "    $comp: $count alerts"
          done
        else
          echo ""
          echo "  ⚠ WARNING: No alert-to-component mappings found!"
          echo "  This may indicate that health-analyzer is not properly exposing metrics."
        fi
      fi
    else
      echo "✗ Failed to query cluster_health_components_map metric ${stage}"
      if [ "$is_detailed" = "true" ]; then
        echo "  This is CRITICAL as it indicates health-analyzer metrics are not being scraped."
      fi
    fi
    
    echo ""
    echo "4. Querying components:health:map metric (legacy format) ${stage}:"
    RESULT_MAP_LEGACY=$(oc exec -n openshift-monitoring "$PROM_POD" -c prometheus -- curl -s -G "http://localhost:9090/api/v1/query" --data-urlencode 'query=components:health:map' 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$RESULT_MAP_LEGACY" ]; then
      echo "$RESULT_MAP_LEGACY" | jq '.' || echo "$RESULT_MAP_LEGACY"
      
      MAP_LEGACY_STATUS=$(echo "$RESULT_MAP_LEGACY" | jq -r '.status' 2>/dev/null)
      MAP_LEGACY_COUNT=$(echo "$RESULT_MAP_LEGACY" | jq -r '.data.result | length' 2>/dev/null)
      
      echo ""
      echo "Verification:"
      echo "  Status: $MAP_LEGACY_STATUS $([ "$MAP_LEGACY_STATUS" = "success" ] && echo "✓" || echo "✗")"
      echo "  Number of legacy alert-to-component mappings: $MAP_LEGACY_COUNT $([ "$MAP_LEGACY_COUNT" -gt 0 ] && echo "✓" || echo "✗ (no mappings found)")"
      
      # Show detailed info if in detailed mode and mappings exist
      if [ "$is_detailed" = "true" ]; then
        if [ "$MAP_LEGACY_COUNT" -gt 0 ]; then
          echo ""
          echo "  Sample legacy alert-to-component mappings (first 10):"
          echo "$RESULT_MAP_LEGACY" | jq -r '.data.result[0:10][] | "    Alert: \(.metric.alert) -> Component: \(.metric.component)"' 2>/dev/null || echo "    Failed to parse mappings"
          
          echo ""
          echo "  Unique components in legacy mappings:"
          echo "$RESULT_MAP_LEGACY" | jq -r '.data.result[].metric.component' 2>/dev/null | sort | uniq -c | while read count comp; do
            echo "    $comp: $count alerts"
          done
        else
          echo ""
          echo "  Note: Legacy metric format (components:health:map) has no results."
          echo "  This may be expected if only the new format (cluster_health_components_map) is in use."
        fi
      fi
    else
      echo "✗ Failed to query components:health:map metric ${stage}"
      if [ "$is_detailed" = "true" ]; then
        echo "  Note: Legacy format may not be present if only new format is supported."
      fi
    fi
    
    # Only check Prometheus targets in detailed mode (after tests)
    if [ "$is_detailed" = "true" ]; then
      echo ""
      echo "5. Checking Prometheus targets for health-analyzer:"
      TARGETS=$(oc exec -n openshift-monitoring "$PROM_POD" -c prometheus -- curl -s "http://localhost:9090/api/v1/targets" 2>/dev/null)
      if [ $? -eq 0 ] && [ -n "$TARGETS" ]; then
        echo "Searching for health-analyzer in Prometheus targets..."
        HEALTH_TARGETS=$(echo "$TARGETS" | jq '.data.activeTargets[] | select(.labels.job | contains("health")) | {job: .labels.job, health: .health, lastError: .lastError}' 2>/dev/null)
        if [ -n "$HEALTH_TARGETS" ]; then
          echo "Health-analyzer related targets:"
          echo "$HEALTH_TARGETS" | jq '.'
        else
          echo "  No health-analyzer targets found in Prometheus"
          echo "  This means Prometheus may not be configured to scrape health-analyzer"
        fi
      else
        echo "  Failed to query Prometheus targets"
      fi
    fi
  else
    echo "✗ No Prometheus pods found in openshift-monitoring namespace ${stage}"
    echo "Available pods in openshift-monitoring:"
    oc get pods -n openshift-monitoring | grep prometheus || echo "No prometheus pods"
  fi
}

## Add IDP for testing
# prepare users
users=""
htpass_file=/tmp/monitoring-plugin-users.htpasswd

for i in $(seq 1 5); do
    username="monitoring-test-${i}"
    password=$(tr </dev/urandom -dc 'a-z0-9' | fold -w 12 | head -n 1 || true)
    users+="${username}:${password},"
    if [ -f "${htpass_file}" ]; then
        htpasswd -B -b ${htpass_file} "${username}" "${password}"
    else
        htpasswd -c -B -b ${htpass_file} "${username}" "${password}"
    fi
done

# remove trailing ',' for case parsing
users=${users%?}

# current generation
gen=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')

# add users to cluster
oc create secret generic monitoring-plugin-htpass-secret --from-file=htpasswd=${htpass_file} -n openshift-config
oc patch oauth cluster --type='json' -p='[{"op": "add", "path": "/spec/identityProviders/-", "value": {"type": "HTPasswd", "name": "monitoring-plugin-htpasswd-idp", "mappingMethod": "claim", "htpasswd":{"fileData":{"name": "monitoring-plugin-htpass-secret"}}}}]'

## wait for oauth-openshift to rollout
wait_auth=true
expected_replicas=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.spec.replicas}')
while $wait_auth; do
    available_replicas=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.status.availableReplicas}')
    new_gen=$(oc get deployment oauth-openshift -n openshift-authentication -o jsonpath='{.metadata.generation}')
    if [[ $expected_replicas == "$available_replicas" && $((new_gen)) -gt $((gen)) ]]; then
        wait_auth=false
    else
        sleep 10
    fi
done
echo "authentication operator finished updating"

# Copy the artifacts to the aritfact directory at the end of the test run.
trap copyArtifacts EXIT

# Validate KUBECONFIG
if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "Error: KUBECONFIG variable is not set"
  exit 0
fi

if [[ ! -f "${KUBECONFIG}" ]]; then
  echo "Error: Kubeconfig file ${KUBECONFIG} does not exist"
  exit 0
fi

# Set Kubeconfig var for Cypress.
cp -L $KUBECONFIG /tmp/kubeconfig && export CYPRESS_KUBECONFIG_PATH=/tmp/kubeconfig

# Set Cypress base URL var.
console_route=$(oc get route console -n openshift-console -o jsonpath='{.spec.host}')
export CYPRESS_BASE_URL=https://$console_route

# Set Cypress authentication username and password.
# Use the IDP once issue https://issues.redhat.com/browse/OCPBUGS-59366 is fixed.
#export CYPRESS_LOGIN_IDP=monitoring-plugin-htpasswd-idp
#export CYPRESS_LOGIN_USERS=${users}
export CYPRESS_LOGIN_IDP=kube:admin
export CYPRESS_LOGIN_USERS=kubeadmin:${kubeadmin_password}

# Run the Cypress tests.
export NO_COLOR=1
export CYPRESS_CACHE_FOLDER=/tmp/Cypress

# Define the repository URL and target directory
repo_url="https://github.com/DavidRajnoha/monitoring-plugin.git"
target_dir="/tmp/monitoring-plugin"

# Determine the branch to clone
branch="${MONITORING_PLUGIN_BRANCH:-main}"

echo "Cloning monitoring-plugin repository, branch: $branch"
git clone --depth 1 --branch "$branch" "$repo_url" "$target_dir"
if [ $? -eq 0 ]; then
  cd "$target_dir" || exit 0
  echo "Successfully cloned the repository and changed directory to $target_dir."
else
  echo "Error cloning the repository."
  exit 0
fi

# Start memory monitoring in the background
monitorMemory &
MEMORY_MONITOR_PID=$!
echo "Memory monitor started with PID: ${MEMORY_MONITOR_PID}"

# Install npm modules
ls -ltr
echo "Installing npm dependencies..."
cd web || exit 0
ls -ltr

npm install || true

# Check if health-analyzer is running before tests
echo "=== Listing all pods in namespace ${CYPRESS_COO_NAMESPACE} ==="
oc get pods -n "${CYPRESS_COO_NAMESPACE}" -o wide || echo "No pods found or namespace doesn't exist"

echo ""
echo "=== Checking for health-analyzer deployment in namespace ${CYPRESS_COO_NAMESPACE} ==="
if oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" &>/dev/null; then
  echo "health-analyzer deployment found in ${CYPRESS_COO_NAMESPACE}"
  oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}"
  
  echo ""
  echo "Deployment spec.replicas:"
  oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" -o jsonpath='{.spec.replicas}'
  echo ""
  
  echo ""
  echo "Deployment selector (what labels it uses to find pods):"
  oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" -o jsonpath='{.spec.selector.matchLabels}' | jq '.'
  echo ""
  
  echo ""
  echo "Deployment pod template labels (what labels pods will have):"
  oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" -o jsonpath='{.spec.template.metadata.labels}' | jq '.'
  echo ""
  
  echo ""
  echo "Deployment status (replicas, conditions):"
  oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" -o jsonpath='{.status}' | jq '.' || oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" -o yaml | grep -A 20 "status:"
  
  echo ""
  echo "ReplicaSets owned by health-analyzer deployment:"
  oc get replicaset -n "${CYPRESS_COO_NAMESPACE}" -o json | jq -r ".items[] | select(.metadata.ownerReferences[]?.name == \"health-analyzer\") | .metadata.name" | while read rs; do
    if [ -n "$rs" ]; then
      echo "ReplicaSet: $rs"
      oc get replicaset "$rs" -n "${CYPRESS_COO_NAMESPACE}" -o wide
      echo "ReplicaSet selector:"
      oc get replicaset "$rs" -n "${CYPRESS_COO_NAMESPACE}" -o jsonpath='{.spec.selector.matchLabels}' | jq '.'
      echo ""
    fi
  done
  
  echo ""
  echo "Attempting to find pods using deployment's actual selector:"
  SELECTOR=$(oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" -o jsonpath='{.spec.selector.matchLabels}' | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
  echo "Using selector: $SELECTOR"
  if [ -n "$SELECTOR" ]; then
    oc get pods -n "${CYPRESS_COO_NAMESPACE}" -l "$SELECTOR" -o wide || echo "No pods found with this selector"
    
    echo ""
    echo "Logs from health-analyzer pods:"
    POD_NAMES=$(oc get pods -n "${CYPRESS_COO_NAMESPACE}" -l "$SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -n "$POD_NAMES" ]; then
      for pod in $POD_NAMES; do
        echo "--- Logs from pod: $pod ---"
        oc logs "$pod" -n "${CYPRESS_COO_NAMESPACE}" --tail=50 || echo "Failed to get logs from $pod"
        echo ""
      done
    else
      echo "No health-analyzer pods found to get logs from"
    fi
  fi
  
  echo ""
  echo "=== Checking for Prometheus pods in namespace ${CYPRESS_COO_NAMESPACE} ==="
  PROM_PODS=$(oc get pods -n "${CYPRESS_COO_NAMESPACE}" -o name 2>/dev/null | grep -i prometheus)
  if [ -n "$PROM_PODS" ]; then
    echo "Prometheus pods found:"
    oc get pods -n "${CYPRESS_COO_NAMESPACE}" -o wide | grep -i prometheus
    echo ""
    echo "Logs from Prometheus pods:"
    echo "$PROM_PODS" | while read pod_name; do
      pod=$(echo "$pod_name" | sed 's#pod/##')
      echo "--- Logs from $pod ---"
      oc logs "$pod" -n "${CYPRESS_COO_NAMESPACE}" --tail=50 || echo "Failed to get logs from $pod"
      echo ""
    done
  else
    echo "No Prometheus pods found in namespace ${CYPRESS_COO_NAMESPACE}"
  fi
  
  echo ""
  echo "Recent events in namespace ${CYPRESS_COO_NAMESPACE}:"
  oc get events -n "${CYPRESS_COO_NAMESPACE}" --sort-by='.lastTimestamp' | tail -20
  
  oc wait --for=condition=available --timeout=60s deployment/health-analyzer -n "${CYPRESS_COO_NAMESPACE}" || echo "Warning: health-analyzer deployment not yet available"
else
  echo "Warning: health-analyzer deployment not found in ${CYPRESS_COO_NAMESPACE}"
fi

echo ""
echo "=== Searching for pods with 'health-analyzer' in name across namespace ${CYPRESS_COO_NAMESPACE} ==="
oc get pods -n "${CYPRESS_COO_NAMESPACE}" 2>/dev/null | grep -i "health-analyzer" || echo "No pods with 'health-analyzer' in name found"

echo ""
echo "=== Checking for health-analyzer across all namespaces ==="
oc get pods --all-namespaces -l app=health-analyzer -o wide 2>/dev/null || echo "No health-analyzer pods found by label in any namespace"
oc get pods --all-namespaces 2>/dev/null | grep -i "health-analyzer" || echo "No pods with 'health-analyzer' in name found in any namespace"

# Verify UIPlugin and metrics before tests
verify_uiplugin_status "before tests"
verify_metrics_exposure "before tests"

npm run test-cypress-incidents || true
# npm run test-cypress-incidents-regression || true

# Check if health-analyzer is still running after tests
echo ""
echo "=== Listing all pods in namespace ${CYPRESS_COO_NAMESPACE} after tests ==="
oc get pods -n "${CYPRESS_COO_NAMESPACE}" -o wide || echo "No pods found or namespace doesn't exist"

echo ""
echo "=== Checking for health-analyzer deployment in namespace ${CYPRESS_COO_NAMESPACE} after tests ==="
if oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" &>/dev/null; then
  echo "health-analyzer deployment still present in ${CYPRESS_COO_NAMESPACE}"
  oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}"
  
  echo ""
  echo "Deployment spec.replicas:"
  oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" -o jsonpath='{.spec.replicas}'
  echo ""
  
  echo ""
  echo "Deployment status (replicas, conditions):"
  oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" -o jsonpath='{.status}' | jq '.' || oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" -o yaml | grep -A 20 "status:"
  
  echo ""
  echo "Attempting to find pods using deployment's actual selector:"
  SELECTOR=$(oc get deployment health-analyzer -n "${CYPRESS_COO_NAMESPACE}" -o jsonpath='{.spec.selector.matchLabels}' | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")')
  echo "Using selector: $SELECTOR"
  if [ -n "$SELECTOR" ]; then
    oc get pods -n "${CYPRESS_COO_NAMESPACE}" -l "$SELECTOR" -o wide || echo "No pods found with this selector"
    
    echo ""
    echo "Logs from health-analyzer pods after tests:"
    POD_NAMES=$(oc get pods -n "${CYPRESS_COO_NAMESPACE}" -l "$SELECTOR" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [ -n "$POD_NAMES" ]; then
      for pod in $POD_NAMES; do
        echo "--- Logs from pod: $pod ---"
        oc logs "$pod" -n "${CYPRESS_COO_NAMESPACE}" --tail=50 || echo "Failed to get logs from $pod"
        echo ""
      done
    else
      echo "No health-analyzer pods found to get logs from"
    fi
  fi
  
  echo ""
  echo "=== Checking for Prometheus pods in namespace ${CYPRESS_COO_NAMESPACE} after tests ==="
  PROM_PODS=$(oc get pods -n "${CYPRESS_COO_NAMESPACE}" -o name 2>/dev/null | grep -i prometheus)
  if [ -n "$PROM_PODS" ]; then
    echo "Prometheus pods found:"
    oc get pods -n "${CYPRESS_COO_NAMESPACE}" -o wide | grep -i prometheus
    echo ""
    echo "Logs from Prometheus pods:"
    echo "$PROM_PODS" | while read pod_name; do
      pod=$(echo "$pod_name" | sed 's#pod/##')
      echo "--- Logs from $pod ---"
      oc logs "$pod" -n "${CYPRESS_COO_NAMESPACE}" --tail=50 || echo "Failed to get logs from $pod"
      echo ""
    done
  else
    echo "No Prometheus pods found in namespace ${CYPRESS_COO_NAMESPACE} after tests"
  fi
  
  echo ""
  echo "Recent events in namespace ${CYPRESS_COO_NAMESPACE} after tests:"
  oc get events -n "${CYPRESS_COO_NAMESPACE}" --sort-by='.lastTimestamp' | tail -20
else
  echo "Warning: health-analyzer deployment not found in ${CYPRESS_COO_NAMESPACE} after tests"
fi

echo ""
echo "=== Searching for pods with 'health-analyzer' in name across namespace ${CYPRESS_COO_NAMESPACE} after tests ==="
oc get pods -n "${CYPRESS_COO_NAMESPACE}" 2>/dev/null | grep -i "health-analyzer" || echo "No pods with 'health-analyzer' in name found"

echo ""
echo "=== Checking for health-analyzer across all namespaces after tests ==="
oc get pods --all-namespaces -l app=health-analyzer -o wide 2>/dev/null || echo "No health-analyzer pods found by label in any namespace"
oc get pods --all-namespaces 2>/dev/null | grep -i "health-analyzer" || echo "No pods with 'health-analyzer' in name found in any namespace"

# Verify UIPlugin and metrics after tests
verify_uiplugin_status "after tests"
verify_metrics_exposure "after tests"
