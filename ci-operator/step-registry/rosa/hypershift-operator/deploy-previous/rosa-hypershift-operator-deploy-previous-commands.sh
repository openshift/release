#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

collect_previous_rollout_diagnostics() {
  set +x
  [[ -n "${ARTIFACT_DIR:-}" && -f "${MC_KUBECONFIG:-}" && -r "${MC_KUBECONFIG}" && -s "${MC_KUBECONFIG}" ]] || return 0
  grep -q '[^[:space:]]' "${MC_KUBECONFIG}" || return 0
  local destination="${ARTIFACT_DIR}/ho-deploy-previous"
  mkdir -p "${destination}" || return 0

  diagnostic_get() {
    timeout --foreground --kill-after=1s 8s oc --kubeconfig="${MC_KUBECONFIG}" --request-timeout=5s \
      -n hypershift get "$@" -o json 2>/dev/null
  }

  local projection='
    def reason:
      if IN("CrashLoopBackOff", "ImagePullBackOff", "ErrImagePull", "ContainerCreating",
            "PodInitializing", "CreateContainerConfigError", "CreateContainerError",
            "RunContainerError", "Error", "Completed", "OOMKilled", "DeadlineExceeded",
            "ProgressDeadlineExceeded", "ReplicaSetUpdated", "NewReplicaSetAvailable",
            "MinimumReplicasUnavailable", "MinimumReplicasAvailable", "FailedCreate",
            "FailedScheduling", "Failed", "BackOff", "Pulling", "Pulled", "Created",
            "Started", "Killing", "Unhealthy", "ScalingReplicaSet", "FailedMount") then . else "Other" end;
    def timestamp:
      if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$")
      then . else null end;
    def time_key:
      if . == null then "" else
        capture("^(?<second>[^.Z]+)(\\.(?<fraction>[0-9]+))?Z$") |
        .second + "." + (((.fraction // "") + "000000000")[:9]) + "Z"
      end;
    def identity: {name: .metadata.name, uid: .metadata.uid};
    def conditions: [.[]? | {type, status, reason: (.reason | reason)}];
    def state:
      {waiting: (if .waiting then {reason: (.waiting.reason | reason)} else null end),
       terminated: (if .terminated then {reason: (.terminated.reason | reason), exitCode: .terminated.exitCode,
                                        signal: .terminated.signal} else null end),
       running: (.running != null)};
    def containers: [.[]? | {name, ready, restartCount, image, imageID,
                            state: (.state | state), lastState: (.lastState | state)}];
    def replicas: {replicas, readyReplicas, availableReplicas, unavailableReplicas,
                   updatedReplicas, fullyLabeledReplicas, observedGeneration};
    def workload:
      identity + {generation: .metadata.generation,
                  desiredReplicas: .spec.replicas, status: (.status | replicas),
                  images: [.spec.template.spec.containers[]? | {name, image}],
                  conditions: (.status.conditions | conditions)};
    def pod:
      identity + {phase: .status.phase, conditions: (.status.conditions | conditions),
                  containers: (.status.containerStatuses | containers),
                  initContainers: (.status.initContainerStatuses | containers)};
  '
  local deployment selector deployment_uid replicas pods resource_uid
  deployment=$(diagnostic_get deployment operator) || return 0
  printf '%s' "${deployment}" | jq -e "${projection} workload" > "${destination}/deployment.json" || return 0
  deployment_uid=$(printf '%s' "${deployment}" | jq -er '.metadata.uid | select(type == "string" and test("^[a-zA-Z0-9-]+$"))') || return 0
  selector=$(printf '%s' "${deployment}" | jq -er '
    .spec.selector |
    [((.matchLabels // {}) | to_entries[] | "\(.key)=\(.value)"),
     (.matchExpressions // [] | .[] |
      if .operator == "In" then "\(.key) in (\(.values | join(",")))"
      elif .operator == "NotIn" then "\(.key) notin (\(.values | join(",")))"
      elif .operator == "Exists" then .key
      elif .operator == "DoesNotExist" then "!\(.key)"
      else error("unsupported selector") end)] | join(",") | select(length > 0)
  ') || return 0
  replicas=$(diagnostic_get replicasets --selector="${selector}" | jq -ce --arg uid "${deployment_uid}" '
    [.items[] | select(any(.metadata.ownerReferences[]?; .uid == $uid and .controller == true))] |
    sort_by([(.spec.replicas // 0), (.metadata.creationTimestamp // "")]) | reverse
  ') || replicas='[]'
  printf '%s' "${replicas}" | jq "${projection} .[:10] | map(workload)" > "${destination}/replicasets.json" || true
  pods=$(diagnostic_get pods --selector="${selector}" | jq -ce --argjson replicas "${replicas}" '
    [.items[] | select(any(.metadata.ownerReferences[]?;
      .uid as $uid | .controller == true and any($replicas[]; .metadata.uid == $uid)))] |
    sort_by(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .[:10]
  ') || pods='[]'
  printf '%s' "${pods}" | jq "${projection} map(pod)" > "${destination}/pods.json" || true
  while IFS= read -r resource_uid; do
    diagnostic_get events --field-selector="involvedObject.uid=${resource_uid}" | \
      jq --arg uid "${resource_uid}" "${projection}"'
        [.items[] | select(.involvedObject.uid == $uid) |
          {type, reason: (.reason | reason), count,
           firstTimestamp: (.firstTimestamp | timestamp), lastTimestamp: (.lastTimestamp | timestamp),
           eventTime: (.eventTime | timestamp),
           creationTimestamp: (.metadata.creationTimestamp | timestamp),
           series: (if .series then {count: .series.count,
                    lastObservedTime: (.series.lastObservedTime | timestamp)} else null end)}] |
        sort_by((.series.lastObservedTime // .lastTimestamp // .eventTime //
                 .firstTimestamp // .creationTimestamp) | time_key) | reverse | .[:20]
      ' > "${destination}/events-${resource_uid}.json" || true
  done < <(printf '%s\n%s\n%s' "${deployment}" "${pods}" "${replicas}" | jq -r '
    (if type == "array" then .[] else . end) | .metadata.uid |
    select(type == "string" and test("^[a-zA-Z0-9-]+$"))' | head -n 11)
}

# Log in to OCM
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
OCM_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi

if [[ -z "${CLUSTER_SECTOR}" ]]; then
  echo "CLUSTER_SECTOR is required"
  exit 1
fi

# Resolve the MC from the sector via OSDFM API
echo "Looking up management cluster for sector '${CLUSTER_SECTOR}' in region '${REGION}'..."
MC_CLUSTER_ID=""
for status in ready maintenance; do
  MC_CLUSTER_ID=$(ocm get /api/osd_fleet_mgmt/v1/management_clusters \
    --parameter search="sector is '${CLUSTER_SECTOR}' and region is '${REGION}' and status in ('${status}')" \
    | jq -r '.items[0].cluster_management_reference.cluster_id // empty')
  if [[ -n "${MC_CLUSTER_ID}" ]]; then
    echo "Found MC with status '${status}'"
    break
  fi
done

if [[ -z "${MC_CLUSTER_ID}" ]]; then
  echo "No management cluster found for sector '${CLUSTER_SECTOR}' in region '${REGION}'"
  exit 1
fi

# Get MC name for logging
MC_NAME=$(ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}" | jq -r .name)
echo "Management cluster: ${MC_NAME} (${MC_CLUSTER_ID})"

# Get MC kubeconfig
MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"
ocm get "/api/clusters_mgmt/v1/clusters/${MC_CLUSTER_ID}/credentials" | jq -r .kubeconfig > "${MC_KUBECONFIG}"
echo "${MC_NAME}" > "${SHARED_DIR}/mc-cluster-name"
echo "${MC_CLUSTER_ID}" > "${SHARED_DIR}/mc-cluster-id"

# Check if the MC is locked by a PR test job
EXISTING_LOCK=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap ho-deploy-lock -n hypershift -o jsonpath='{.data.job}' 2>/dev/null || true)
if [[ -n "${EXISTING_LOCK}" ]]; then
  LOCK_TIME=$(KUBECONFIG="${MC_KUBECONFIG}" oc get configmap ho-deploy-lock -n hypershift -o jsonpath='{.data.acquired}' 2>/dev/null || echo "unknown")
  echo "MC is locked by a PR test job: ${EXISTING_LOCK} (acquired: ${LOCK_TIME})"
  echo "Skipping HO deployment to avoid conflicting with the PR test."
  exit 0
fi

# Resolve the HO image from the RHTAP build pipeline (quay.io)
HO_REPO="quay.io/acm-d/rhtap-hypershift-operator"
HO_OFFSET="${HO_VERSION_OFFSET:-0}"
echo "Looking up HO image from ${HO_REPO} (offset=${HO_OFFSET})..."
LATEST_DIGEST=$(curl -s "https://quay.io/api/v1/repository/acm-d/rhtap-hypershift-operator/tag/?limit=100&onlyActiveTags=true&filter_tag_name=like:latest-" \
  | jq -r --argjson offset "${HO_OFFSET}" '[.tags[] | select(.name | startswith("latest-"))] | sort_by(.name) | reverse | .[$offset].manifest_digest')

if [[ -z "${LATEST_DIGEST}" || "${LATEST_DIGEST}" == "null" ]]; then
  echo "Failed to resolve latest HO image from Quay"
  exit 1
fi

HO_IMAGE="${HO_REPO}@${LATEST_DIGEST}"
echo "Latest HO image: ${HO_IMAGE}"

# Get current HO image on the MC
CURRENT_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
echo "Current HO image on MC: ${CURRENT_IMAGE}"

if [[ "${CURRENT_IMAGE}" == "${HO_IMAGE}" ]]; then
  echo "MC is already running the latest HO image, skipping deploy"
  exit 0
fi

# Patch the HO deployment with the new image
echo "Deploying HO image to MC..."
KUBECONFIG="${MC_KUBECONFIG}" oc set image deployment/operator -n hypershift \
  operator="${HO_IMAGE}"

# Wait for rollout
echo "Waiting for HO rollout..."
if KUBECONFIG="${MC_KUBECONFIG}" oc rollout status deployment/operator -n hypershift --timeout=300s; then
  :
else
  rollout_status=$?
  export -f collect_previous_rollout_diagnostics
  MC_KUBECONFIG="${MC_KUBECONFIG}" ARTIFACT_DIR="${ARTIFACT_DIR:-}" \
    timeout --signal=KILL 60s bash -c 'collect_previous_rollout_diagnostics' >/dev/null 2>&1 || true
  exit "${rollout_status}"
fi

# Verify the deployment
DEPLOYED_IMAGE=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "Deployed HO image: ${DEPLOYED_IMAGE}"

READY_REPLICAS=$(KUBECONFIG="${MC_KUBECONFIG}" oc get deployment operator -n hypershift -o jsonpath='{.status.readyReplicas}')
echo "Ready replicas: ${READY_REPLICAS}"

if [[ "${READY_REPLICAS}" -lt 1 ]]; then
  echo "HO deployment has no ready replicas after rollout!"
  exit 1
fi

echo "HyperShift operator successfully deployed to ${MC_NAME}"
