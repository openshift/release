#!/bin/bash
set +x
set -euo pipefail

[[ "${HO_MINIMAL_DIAGNOSTICS:-false}" == true ]] || exit 0

write_bundle() {
  local temporary
  mkdir -p "${ARTIFACT_DIR}" || return 1
  temporary=$(mktemp "${ARTIFACT_DIR}/.ho-minimal.XXXXXX") || return 1
  if printf '%s\n' "$1" > "${temporary}" && mv -f "${temporary}" "${ARTIFACT_DIR}/ho-minimal-diagnostics.json"; then
    return 0
  fi
  rm -f "${temporary}"
  return 1
} 2>/dev/null

failure_bundle() {
  printf '{"schemaVersion":1,"outcome":"failed","failure":"%s","truncated":false}\n' "$1"
}

if [[ "${1:-}" != collect ]]; then
  for tool in bash timeout head jq oc; do
    if ! command -v "${tool}" >/dev/null; then
      write_bundle "$(failure_bundle missing_tool)" || echo 'HO minimum diagnostics: artifact write failed' >&2
      exit 0
    fi
  done
  result=''
  if result=$(timeout -k 2s 60s bash "$0" collect 2>/dev/null | head -c 262145); then
    if [[ ${#result} -le 262144 ]] && jq -e '.schemaVersion == 1 and (.outcome == "complete" or .outcome == "partial" or .outcome == "failed")' <<< "${result}" >/dev/null 2>&1; then
      write_bundle "${result}" || echo 'HO minimum diagnostics: artifact write failed' >&2
    else
      write_bundle "$(failure_bundle invalid_output)" || echo 'HO minimum diagnostics: artifact write failed' >&2
    fi
  else
    write_bundle "$(failure_bundle collector_failed)" || echo 'HO minimum diagnostics: artifact write failed' >&2
  fi
  exit 0
fi

ulimit -t 10
ulimit -c 0
export LC_ALL=C
function jq() (
  ulimit -v 131072
  command jq "$@"
)
REQUEST_COUNT=0
RESPONSE='{}'
REQUEST_OUTCOME=request_failed
CATEGORIES='{}'
MC_KUBECONFIG="${SHARED_DIR}/hs-mc.kubeconfig"

FILTER=$(cat <<'JQ'
def number_value: if type == "number" and . >= 0 and . <= 2147483647 and floor == . then . else null end;
def timestamp: if type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") then . else null end;
def choice($values): if . as $value | $values | index($value) then . else "Other" end;
def conditions: [.status.conditions[:16][]? | select(.type as $value | ["Available","Progressing","Degraded","Ready","Upgradeable","ValidConfiguration","SupportedHostedCluster"] | index($value)) | {type, status: (.status | choice(["True","False","Unknown"])), observedGeneration: (.observedGeneration | number_value), lastTransitionTime: (.lastTransitionTime | timestamp)}];
def generations: {generation: (.metadata.generation | number_value), observedGeneration: (.status.observedGeneration | number_value)};
def replicas: generations + {desired: (.spec.replicas | number_value), current: (.status.replicas | number_value), updated: (.status.updatedReplicas | number_value), ready: (.status.readyReplicas | number_value), available: (.status.availableReplicas | number_value), unavailable: (.status.unavailableReplicas | number_value)};
def reason: choice(["Completed","Error","OOMKilled","ContainerCannotRun","CrashLoopBackOff","ImagePullBackOff","ErrImagePull","CreateContainerConfigError","PodInitializing","ContainerCreating","Unschedulable","SchedulingGated","Scheduled","FailedScheduling","FailedMount","FailedAttachVolume","BackOff","Pulled","Pulling","Created","Started","Killing","Unhealthy","Failed"]);
def state: if .terminated then {state:"terminated",exitCode:(.terminated.exitCode | number_value),signal:(.terminated.signal | number_value),reason:(.terminated.reason | reason),startedAt:(.terminated.startedAt | timestamp),finishedAt:(.terminated.finishedAt | timestamp)} elif .waiting then {state:"waiting",reason:(.waiting.reason | reason)} elif .running then {state:"running",startedAt:(.running.startedAt | timestamp)} else {state:"unknown"} end;
def pod: {phase:(.status.phase | choice(["Pending","Running","Succeeded","Failed","Unknown"])),assignedNode:((.spec.nodeName // "") != ""),scheduled:([.status.conditions[]? | select(.type == "PodScheduled") | .status | choice(["True","False","Unknown"])][0] // null),containers:[(.status.initContainerStatuses[:4][]?, .status.containerStatuses[:4][]?) | {ready:(.ready == true),restartCount:(.restartCount | number_value),current:(.state | state),previous:(.lastState | state)}]};
def event: {type:(.type | choice(["Normal","Warning"])),reason:(.reason | reason),count:(.count | number_value),firstTimestamp:(.firstTimestamp | timestamp),lastTimestamp:(.lastTimestamp | timestamp)};
JQ
)

request() {
  local path="$1"
  REQUEST_COUNT=$((REQUEST_COUNT + 1))
  REQUEST_OUTCOME=request_failed
  RESPONSE='{}'
  [[ ${REQUEST_COUNT} -le 18 ]] || return 1
  if ! RESPONSE=$(timeout -k 1s 4s oc --kubeconfig="${MC_KUBECONFIG}" --request-timeout=3s get --raw "${path}" 2>/dev/null | head -c 1048577); then
    return 1
  fi
  if [[ ${#RESPONSE} -gt 1048576 ]]; then
    REQUEST_OUTCOME=oversized
    return 1
  fi
  if ! jq -e 'type == "object"' <<< "${RESPONSE}" >/dev/null 2>&1; then
    REQUEST_OUTCOME=invalid_response
    return 1
  fi
}

category() {
  CATEGORIES=$(jq -c --arg key "$1" --arg outcome "$2" --argjson items "${3:-[]}" --argjson truncated "${4:-false}" '. + {($key): {outcome:$outcome,items:$items,truncated:$truncated}}' <<< "${CATEGORIES}")
}

project() {
  jq -ce "${FILTER} $1" <<< "${RESPONSE}"
}

valid_name() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]{0,61}[a-z0-9])?$ ]]
}

list_valid() {
  jq -e '.items | type == "array" and length <= 32' <<< "${RESPONSE}" >/dev/null
}

conditions_category() {
  local key="$1"
  category "${key}" complete "$(project '[generations + {conditions:conditions}]')" "$(jq '(.status.conditions | length) > 16' <<< "${RESPONSE}")"
}

workload() {
  local role="$1" namespace="$2" name="$3" deployment_uid selector encoded rs_uids pods pod_uid events='[]' truncated=false
  if ! request "/apis/apps/v1/namespaces/${namespace}/deployments/${name}"; then
    category "${role}Deployment" "${REQUEST_OUTCOME}"
    return
  fi
  if ! jq -e --arg namespace "${namespace}" --arg name "${name}" '.metadata.namespace == $namespace and .metadata.name == $name and (.metadata.uid | type == "string" and length > 0) and (.spec.selector.matchLabels | type == "object" and length > 0) and ((.spec.selector.matchExpressions // []) | length == 0)' <<< "${RESPONSE}" >/dev/null; then
    category "${role}Deployment" invalid_target
    return
  fi
  deployment_uid=$(jq -r '.metadata.uid' <<< "${RESPONSE}")
  if ! selector=$(jq -er '.spec.selector.matchLabels | to_entries | if length > 0 and length <= 16 and all(.[]; (.key | test("^[a-zA-Z0-9./_-]{1,253}$")) and (.value | type == "string" and test("^[a-zA-Z0-9._-]{1,63}$"))) then map(.key + "=" + .value) | join(",") else error("selector") end' <<< "${RESPONSE}"); then
    category "${role}Deployment" invalid_target
    return
  fi
  encoded=$(jq -rn --arg value "${selector}" '$value | @uri')
  category "${role}Deployment" complete "$(project '[replicas]')"
  if ! request "/apis/apps/v1/namespaces/${namespace}/replicasets?labelSelector=${encoded}&limit=17" || ! list_valid; then
    category "${role}ReplicaSets" "${REQUEST_OUTCOME}"
    return
  fi
  RESPONSE=$(jq -c --arg uid "${deployment_uid}" --arg namespace "${namespace}" '.items |= map(select(.metadata.namespace == $namespace and any(.metadata.ownerReferences[]?; .uid == $uid and .kind == "Deployment" and .controller == true)))' <<< "${RESPONSE}")
  rs_uids=$(jq -c '[.items[:8][] | .metadata.uid | select(type == "string" and length > 0)]' <<< "${RESPONSE}")
  truncated=$(jq '((.metadata.continue // "") != "") or (.items | length > 8)' <<< "${RESPONSE}")
  category "${role}ReplicaSets" "$(jq -r 'if (.items | length) > 0 then "complete" else "unavailable" end' <<< "${RESPONSE}")" "$(project '[.items[:8][] | replicas]')" "${truncated}"
  if ! request "/api/v1/namespaces/${namespace}/pods?labelSelector=${encoded}&limit=17" || ! list_valid; then
    category "${role}Pods" "${REQUEST_OUTCOME}"
    return
  fi
  RESPONSE=$(jq -c --argjson uids "${rs_uids}" --arg namespace "${namespace}" '.items |= map(select(.metadata.namespace == $namespace and any(.metadata.ownerReferences[]?; .uid as $uid | .kind == "ReplicaSet" and .controller == true and ($uids | index($uid)))))' <<< "${RESPONSE}")
  pods=$(jq -c '.items[:8]' <<< "${RESPONSE}")
  truncated=$(jq '((.metadata.continue // "") != "") or (.items | length > 8) or any(.items[]; (.status.containerStatuses | length) > 4 or (.status.initContainerStatuses | length) > 4)' <<< "${RESPONSE}")
  category "${role}Pods" "$(jq -r 'if (.items | length) > 0 then "complete" else "unavailable" end' <<< "${RESPONSE}")" "$(project '[.items[:8][] | pod]')" "${truncated}"
  truncated=$(jq 'length > 2' <<< "${pods}")
  local event_outcome=complete
  while IFS= read -r pod_uid; do
    encoded=$(jq -rn --arg value "involvedObject.uid=${pod_uid}" '$value | @uri')
    if ! request "/api/v1/namespaces/${namespace}/events?fieldSelector=${encoded}&limit=9" || ! list_valid; then
      event_outcome=request_failed
      continue
    fi
    if [[ $(jq '((.metadata.continue // "") != "") or (.items | length > 8)' <<< "${RESPONSE}") == true ]]; then
      truncated=true
    fi
    RESPONSE=$(jq -c --arg uid "${pod_uid}" --arg namespace "${namespace}" '.items |= map(select(.metadata.namespace == $namespace and .involvedObject.uid == $uid))' <<< "${RESPONSE}")
    events=$(jq -cn --argjson previous "${events}" --argjson next "$(project '[.items[:8][] | event]')" '$previous + $next')
  done < <(jq -r '.[0:2][] | .metadata.uid | select(type == "string" and test("^[a-zA-Z0-9-]{1,64}$"))' <<< "${pods}")
  category "${role}Events" "${event_outcome}" "${events}" "${truncated}"
}

for key in target hostedCluster hostedControlPlane nodePools catalogDeployment catalogReplicaSets catalogPods catalogEvents operatorDeployment operatorReplicaSets operatorPods operatorEvents; do
  category "${key}" unavailable
done

if [[ ! -s "${MC_KUBECONFIG}" ]]; then
  failure_bundle missing_kubeconfig
  exit 0
fi
cluster_id=$(head -c 64 "${SHARED_DIR}/cluster-id" 2>/dev/null || true)
cluster_name=$(head -c 64 "${SHARED_DIR}/cluster-name" 2>/dev/null || true)
environment="${OCM_LOGIN_ENV:-integration}"
case "${environment}" in
  integration) environment=int ;;
  staging|production) ;;
  *) environment='' ;;
esac
namespace="ocm-${environment}-${cluster_id}-${cluster_name}"
if [[ -n "${environment}" ]] && valid_name "${cluster_id}" && valid_name "${cluster_name}" && valid_name "${namespace}"; then
  if request "/apis/hypershift.openshift.io/v1beta1/namespaces/${namespace}/hostedcontrolplanes?limit=2" && list_valid; then
    if jq -e --arg namespace "${namespace}" '((.metadata.continue // "") == "") and (.items | length == 1 and .[0].metadata.namespace == $namespace)' <<< "${RESPONSE}" >/dev/null; then
      RESPONSE=$(jq -c '.items[0]' <<< "${RESPONSE}")
      hcp="${RESPONSE}"
      hc_identity=$(jq -r '.metadata.annotations["hypershift.openshift.io/cluster"] // ""' <<< "${RESPONSE}")
      hc_namespace="${hc_identity%/*}"
      hc_name="${hc_identity#*/}"
      if valid_name "${hc_namespace}" && valid_name "${hc_name}" && [[ "${hc_name}" == "${cluster_name}" && "${hc_namespace}-${hc_name//./-}" == "${namespace}" ]]; then
        if request "/apis/hypershift.openshift.io/v1beta1/namespaces/${hc_namespace}/hostedclusters/${hc_name}"; then
          if jq -e --arg namespace "${hc_namespace}" --arg name "${hc_name}" --argjson hcp "${hcp}" '.metadata.namespace == $namespace and .metadata.name == $name and (.spec.clusterID | type == "string" and length > 0) and .spec.clusterID == $hcp.spec.clusterID' <<< "${RESPONSE}" >/dev/null; then
            category target complete
            conditions_category hostedCluster
            RESPONSE="${hcp}"
            conditions_category hostedControlPlane
            if request "/apis/hypershift.openshift.io/v1beta1/namespaces/${hc_namespace}/nodepools?limit=17" && list_valid; then
              truncated=$(jq '((.metadata.continue // "") != "") or (.items | length > 8) or any(.items[]; (.status.conditions | length) > 16)' <<< "${RESPONSE}")
              RESPONSE=$(jq -c --arg name "${hc_name}" --arg namespace "${hc_namespace}" '.items |= map(select(.metadata.namespace == $namespace and .spec.clusterName == $name))' <<< "${RESPONSE}")
              category nodePools complete "$(project '[.items[:8][] | generations + {conditions:conditions}]')" "${truncated}"
            else
              category nodePools "${REQUEST_OUTCOME}"
            fi
            workload catalog "${namespace}" redhat-operators-catalog
          else
            category target invalid_target
          fi
        else
          category target "${REQUEST_OUTCOME}"
        fi
      else
        category target invalid_target
      fi
    else
      category target invalid_target '[]' "$(jq '((.metadata.continue // "") != "") or (.items | length > 1)' <<< "${RESPONSE}")"
    fi
  else
    category target "${REQUEST_OUTCOME}"
  fi
else
  category target invalid_target
fi
workload operator hypershift operator
phase="${HO_DIAGNOSTIC_PHASE:-post}"
case "${phase}" in test|before_deploy|deploy|verify|post) ;; *) phase=post ;; esac
jq -cn --arg phase "${phase}" --argjson categories "${CATEGORIES}" '{schemaVersion:1,phase:$phase,outcome:(if all($categories[]; .outcome == "complete" and .truncated == false) then "complete" else "partial" end),truncated:any($categories[]; .truncated),omissions:{logs:"omitted_by_policy",ocm:"not_queried"},categories:$categories}'
