#!/bin/bash

set -euo pipefail
set +x

context_file="$SHARED_DIR/nutanix_context.sh"
trap 'status=$?; if (( status == 0 )); then rm -f "$context_file"; fi' EXIT

if [[ -z "${NUTANIX_QUOTA_SLICE:-}" ]]; then
  echo "NUTANIX_QUOTA_SLICE is required from the workflow lease."
  exit 1
fi
lease_resource=${NUTANIX_QUOTA_SLICE}

if [[ ! -s "$context_file" ]]; then
  if [[ -s "$SHARED_DIR/nutanix_worker_names" || -s "$SHARED_DIR/nutanix_image_name" || -s "$SHARED_DIR/nutanix_infraenv_name" || -s "$SHARED_DIR/nutanix_dns_vm_name" || -s "$SHARED_DIR/nutanix_dns_image_name" || -s "$SHARED_DIR/nutanix_dns_dhcp_state.json" ]]; then
    echo "Nutanix resources may exist but the private Nutanix context is unavailable; cleanup cannot be verified for $lease_resource."
    exit 1
  fi
  exit 0
fi

source "$context_file"
if [[ ! -s "$SHARED_DIR/cluster-name" ]]; then
  if [[ -s "$SHARED_DIR/nutanix_worker_names" || -s "$SHARED_DIR/nutanix_image_name" || -s "$SHARED_DIR/nutanix_infraenv_name" || -s "$SHARED_DIR/nutanix_dns_vm_name" || -s "$SHARED_DIR/nutanix_dns_image_name" || -s "$SHARED_DIR/nutanix_dns_dhcp_state.json" ]]; then
    echo "Run-owned Nutanix resources may exist, but the HostedCluster name is unavailable."
    exit 1
  fi
  exit 0
fi
CLUSTER_NAME=$(cat "$SHARED_DIR/cluster-name")
RUN_LABEL_KEY=ci.openshift.io/hcp-agent-nutanix-run
export KUBECONFIG="$SHARED_DIR/kubeconfig"
management_cleanup_failed=false
worker_cleanup_failed=false

if [[ -s "$SHARED_DIR/nutanix_agent_namespace" || -s "$SHARED_DIR/nutanix_infraenv_name" || -s "$SHARED_DIR/nutanix_pull_secret_name" ]]; then
  AGENT_NAMESPACE=${AGENT_NAMESPACE:-hypershift-agents}
  if [[ -s "$SHARED_DIR/nutanix_agent_namespace" ]]; then
    AGENT_NAMESPACE=$(cat "$SHARED_DIR/nutanix_agent_namespace")
  fi
  oc delete agents -n "$AGENT_NAMESPACE" -l "$RUN_LABEL_KEY=$CLUSTER_NAME" --ignore-not-found --wait=true --timeout=2m || true
  if ! remaining_agents=$(oc get agents -n "$AGENT_NAMESPACE" -l "$RUN_LABEL_KEY=$CLUSTER_NAME" -o name 2>/dev/null); then
    management_cleanup_failed=true
  elif [[ -n "$remaining_agents" ]]; then
    echo "Run-owned Agents remain in namespace $AGENT_NAMESPACE."
    management_cleanup_failed=true
  fi
  if [[ -s "$SHARED_DIR/nutanix_infraenv_name" ]]; then
    INFRAENV_NAME=$(cat "$SHARED_DIR/nutanix_infraenv_name")
    if ! infraenv_json=$(oc get infraenv "$INFRAENV_NAME" -n "$AGENT_NAMESPACE" --ignore-not-found -o json 2>/dev/null); then
      management_cleanup_failed=true
    elif [[ -n "$infraenv_json" ]]; then
      infraenv_run=$(jq -r --arg key "$RUN_LABEL_KEY" '.metadata.labels[$key] // empty' <<<"$infraenv_json")
      if [[ "$infraenv_run" == "$CLUSTER_NAME" ]]; then
        oc delete infraenv "$INFRAENV_NAME" -n "$AGENT_NAMESPACE" --ignore-not-found --wait=true --timeout=2m || true
        if ! remaining_infraenv=$(oc get infraenv "$INFRAENV_NAME" -n "$AGENT_NAMESPACE" --ignore-not-found -o name 2>/dev/null); then
          management_cleanup_failed=true
        elif [[ -n "$remaining_infraenv" ]]; then
          echo "Run-owned InfraEnv $INFRAENV_NAME remains in namespace $AGENT_NAMESPACE."
          management_cleanup_failed=true
        fi
      else
        echo "InfraEnv $INFRAENV_NAME is not labeled as owned by this run; leaving it untouched."
        management_cleanup_failed=true
      fi
    fi
  fi
  if [[ -s "$SHARED_DIR/nutanix_pull_secret_name" ]]; then
    PULL_SECRET_NAME=$(cat "$SHARED_DIR/nutanix_pull_secret_name")
    if ! secret_json=$(oc get secret "$PULL_SECRET_NAME" -n "$AGENT_NAMESPACE" --ignore-not-found -o json 2>/dev/null); then
      management_cleanup_failed=true
    elif [[ -n "$secret_json" ]]; then
      secret_run=$(jq -r --arg key "$RUN_LABEL_KEY" '.metadata.labels[$key] // empty' <<<"$secret_json")
      if [[ "$secret_run" == "$CLUSTER_NAME" ]]; then
        oc delete secret "$PULL_SECRET_NAME" -n "$AGENT_NAMESPACE" --ignore-not-found || true
        if ! remaining_secret=$(oc get secret "$PULL_SECRET_NAME" -n "$AGENT_NAMESPACE" --ignore-not-found -o name 2>/dev/null); then
          management_cleanup_failed=true
        elif [[ -n "$remaining_secret" ]]; then
          echo "Run-owned pull secret $PULL_SECRET_NAME remains in namespace $AGENT_NAMESPACE."
          management_cleanup_failed=true
        fi
      else
        echo "Pull secret $PULL_SECRET_NAME is not labeled as owned by this run; leaving it untouched."
        management_cleanup_failed=true
      fi
    fi
  fi
fi

[[ -f "$SHARED_DIR/vm_uuids.txt" ]] || : > "$SHARED_DIR/vm_uuids.txt"
[[ -f "$SHARED_DIR/image_uuid.txt" ]] || : > "$SHARED_DIR/image_uuid.txt"

recorded_vm_count=$(awk '/^[0-9a-fA-F-]{36}$/ { count++ } END { print count + 0 }' "$SHARED_DIR/vm_uuids.txt")
expected_vm_count=0
if [[ -s "$SHARED_DIR/nutanix_worker_names" ]]; then
  expected_vm_count=$(awk 'NF { count++ } END { print count + 0 }' "$SHARED_DIR/nutanix_worker_names")
fi
if (( recorded_vm_count < expected_vm_count )); then
  response=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    -H 'Content-Type: application/json' -X POST "$NUTANIX_PC_URL/api/nutanix/v3/vms/list" \
    --data '{"kind":"vm","length":500}')
  while IFS= read -r vm_name; do
    [[ -n "$vm_name" ]] || continue
    matches=$(jq -r --arg name "$vm_name" '[.entities[] | select(.spec.name == $name) | .metadata.uuid] | unique | .[]' <<<"$response")
    match_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$matches")
    if (( match_count > 1 )); then
      echo "More than one Nutanix VM has this run's exact worker name $vm_name; refusing broad cleanup."
      exit 1
    fi
    if (( match_count == 1 )) && ! grep -Fxq "$matches" "$SHARED_DIR/vm_uuids.txt"; then
      printf '%s\n' "$matches" >> "$SHARED_DIR/vm_uuids.txt"
    fi
  done < "$SHARED_DIR/nutanix_worker_names"
fi

if [[ -s "$SHARED_DIR/nutanix_image_name" && ! "$(cat "$SHARED_DIR/image_uuid.txt")" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  image_name=$(cat "$SHARED_DIR/nutanix_image_name")
  response=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    -H 'Content-Type: application/json' -X POST "$NUTANIX_PC_URL/api/nutanix/v3/images/list" \
    --data '{"kind":"image","length":500}')
  matches=$(jq -r --arg name "$image_name" '[.entities[] | select(.spec.name == $name) | .metadata.uuid] | unique | .[]' <<<"$response")
  match_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$matches")
  if (( match_count > 1 )); then
    echo "More than one Nutanix image has this run's exact image name $image_name; refusing broad cleanup."
    exit 1
  fi
  if (( match_count == 1 )); then
    printf '%s\n' "$matches" > "$SHARED_DIR/image_uuid.txt"
  fi
fi

mkdir -p "$ARTIFACT_DIR"
cp "$SHARED_DIR/vm_uuids.txt" "$ARTIFACT_DIR/nutanix-vm-uuids.txt"
cp "$SHARED_DIR/image_uuid.txt" "$ARTIFACT_DIR/nutanix-image-uuid.txt"

if [[ -s "$SHARED_DIR/vm_uuids.txt" || -s "$SHARED_DIR/image_uuid.txt" ]]; then
  if [[ -n "${AGENT_QE_INFRA_ANSIBLE_DIR:-}" ]]; then
    ANSIBLE_FILES_DIR=${AGENT_QE_INFRA_ANSIBLE_DIR}
  else
    ANSIBLE_FILES_DIR=/go/src/github.com/openshift-eng/agent-qe-infra/ansible-files
  fi
  if [[ ! -f "$ANSIBLE_FILES_DIR/vars/ci_nutanix.yml" ]]; then
    echo "Cannot delete recorded Nutanix UUIDs without the agent-qe-infra extra ref."
    worker_cleanup_failed=true
  else
    cleanup_playbook=/tmp/hcp-agent-nutanix-cleanup.yml
    cat > "$cleanup_playbook" <<EOF
- name: Delete only run-recorded Nutanix resources
  hosts: localhost
  gather_facts: false
  connection: local
  vars_files:
    - "$ANSIBLE_FILES_DIR/vars/ci_nutanix.yml"
  module_defaults:
    group/nutanix.ncp.ntnx:
      nutanix_username: "{{ lookup('env', 'NUTANIX_USERNAME') }}"
      nutanix_password: "{{ lookup('env', 'NUTANIX_PASSWORD') }}"
      nutanix_host: "{{ lookup('env', 'NUTANIX_HOST') }}"
      validate_certs: false
  tasks:
    - name: Delete recorded worker VMs
      nutanix.ncp.ntnx_vms:
        vm_uuid: "{{ item }}"
        state: absent
      loop: "{{ vm_uuids }}"
      register: vm_deletions
      ignore_errors: true
    - name: Delete recorded discovery image
      nutanix.ncp.ntnx_images:
        image_uuid: "{{ image_uuid }}"
        state: absent
        wait: true
      when: image_uuid | length > 0
      register: image_deletion
      ignore_errors: true
EOF
    ANSIBLE_ROLES_PATH="$ANSIBLE_FILES_DIR/roles" ansible-playbook -i localhost, "$cleanup_playbook" || worker_cleanup_failed=true
  fi
fi

function wait_for_uuid_absent() {
  local endpoint=$1
  local uuid=$2
  local code
  for attempt in $(seq 1 20); do
    code=$(curl --silent --show-error --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
      -o /dev/null -w '%{http_code}' "$NUTANIX_PC_URL/api/nutanix/v3/$endpoint/$uuid") || return 1
    if [[ "$code" == "404" ]]; then
      return 0
    fi
    sleep 15
  done
  return 1
}

function wait_for_dns_task() {
  local task_uuid=$1
  local task_json task_state
  [[ -n "$task_uuid" ]] || return 0
  for attempt in $(seq 1 60); do
    if task_json=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
      "$NUTANIX_PC_URL/api/nutanix/v3/tasks/$task_uuid" 2>/dev/null); then
      task_state=$(jq -r '.status // empty' <<<"$task_json")
      case "$task_state" in
        SUCCEEDED) return 0 ;;
        FAILED|ABORTED)
          echo "Nutanix DNS cleanup task failed: $(jq -r '.error_detail // .progress_message // .status' <<<"$task_json")"
          return 1
          ;;
      esac
    fi
    sleep 10
  done
  echo "Timed out waiting for Nutanix DNS cleanup task $task_uuid."
  return 1
}

function recover_dns_uuid() {
  local kind=$1
  local name_file=$2
  local uuid_file=$3
  local name response matches match_count
  [[ -s "$name_file" ]] || return 0
  if [[ -s "$uuid_file" ]]; then
    return 0
  fi
  name=$(cat "$name_file")
  response=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    -H 'Content-Type: application/json' -X POST "$NUTANIX_PC_URL/api/nutanix/v3/$kind/list" \
    --data "{\"kind\":\"${kind%s}\",\"length\":500}")
  matches=$(jq -r --arg name "$name" '[.entities[]? | select(.spec.name == $name) | .metadata.uuid] | unique | .[]' <<<"$response")
  match_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$matches")
  if (( match_count > 1 )); then
    echo "More than one Nutanix $kind resource has the run-owned name $name; refusing cleanup."
    return 1
  fi
  if (( match_count == 1 )); then
    printf '%s\n' "$matches" > "$uuid_file"
  fi
}

function restore_dns_dhcp() {
  local original_options original_servers target_servers subnet_json current_servers payload response task_uuid restored_servers
  if [[ ! -s "$SHARED_DIR/nutanix_dns_dhcp_state.json" ]]; then
    return 0
  fi
  if [[ "$SUBNET_NAME" != "$lease_resource" ]]; then
    echo "The DNS DHCP state does not match the leased Nutanix subnet."
    return 1
  fi
  if ! jq -e 'has("originalOptions") and (.targetServers | type == "array" and length == 1)' \
    "$SHARED_DIR/nutanix_dns_dhcp_state.json" >/dev/null; then
    echo "The recorded DNS DHCP state is incomplete."
    return 1
  fi
  original_options=$(jq -c '.originalOptions' "$SHARED_DIR/nutanix_dns_dhcp_state.json")
  original_servers=$(jq -nc --argjson options "$original_options" '$options.domain_name_server_list // []')
  target_servers=$(jq -c '.targetServers' "$SHARED_DIR/nutanix_dns_dhcp_state.json")
  subnet_json=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    "$NUTANIX_PC_URL/api/nutanix/v3/subnets/$SUBNET_UUID")
  if [[ $(jq -r '.metadata.uuid // empty' <<<"$subnet_json") != "$SUBNET_UUID" ||
        $(jq -r '.spec.name // empty' <<<"$subnet_json") != "$SUBNET_NAME" ]]; then
    echo "The leased Nutanix subnet changed identity; refusing DHCP restoration."
    return 1
  fi
  current_servers=$(jq -c '.spec.resources.ip_config.dhcp_options.domain_name_server_list // []' <<<"$subnet_json")
  if [[ "$current_servers" == "$original_servers" ]]; then
    return 0
  fi
  if [[ "$current_servers" != "$target_servers" ]]; then
    echo "The subnet's DHCP DNS list changed after this run's update; refusing to overwrite it."
    return 1
  fi
  payload=$(jq --argjson original "$original_options" '
    {api_version,metadata,spec} |
    if $original == null then
      if (.spec.resources.ip_config.dhcp_options | keys) == ["domain_name_server_list"] then
        del(.spec.resources.ip_config.dhcp_options)
      else
        del(.spec.resources.ip_config.dhcp_options.domain_name_server_list)
      end
    elif ($original | has("domain_name_server_list")) then
      .spec.resources.ip_config.dhcp_options.domain_name_server_list = $original.domain_name_server_list
    else
      del(.spec.resources.ip_config.dhcp_options.domain_name_server_list)
    end' <<<"$subnet_json")
  response=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    -H 'Content-Type: application/json' -X PUT "$NUTANIX_PC_URL/api/nutanix/v3/subnets/$SUBNET_UUID" \
    --data-binary "$payload")
  task_uuid=$(jq -r '.status.execution_context.task_uuid // empty' <<<"$response")
  wait_for_dns_task "$task_uuid"
  for attempt in $(seq 1 24); do
    subnet_json=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
      "$NUTANIX_PC_URL/api/nutanix/v3/subnets/$SUBNET_UUID")
    restored_servers=$(jq -c '.spec.resources.ip_config.dhcp_options.domain_name_server_list // []' <<<"$subnet_json")
    if [[ "$restored_servers" == "$original_servers" ]]; then
      return 0
    fi
    sleep 5
  done
  echo "The leased subnet's previous DHCP DNS list was not restored."
  return 1
}

function delete_dns_resource() {
  local kind=$1
  local uuid_file=$2
  local name_file=$3
  local uuid name code response
  [[ -s "$name_file" ]] || return 0
  recover_dns_uuid "$kind" "$name_file" "$uuid_file"
  [[ -s "$uuid_file" ]] || return 0
  uuid=$(cat "$uuid_file")
  name=$(cat "$name_file")
  if [[ ! "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]]; then
    echo "Invalid run-owned Nutanix $kind UUID $uuid."
    return 1
  fi
  code=$(curl --silent --show-error --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    -o /tmp/hcp-agent-nutanix-dns-resource.json -w '%{http_code}' \
    "$NUTANIX_PC_URL/api/nutanix/v3/$kind/$uuid")
  if [[ "$code" == 404 ]]; then
    return 0
  fi
  if [[ "$code" != 200 || $(jq -r '.spec.name // empty' /tmp/hcp-agent-nutanix-dns-resource.json) != "$name" ]]; then
    echo "Run-owned Nutanix $kind $uuid could not be verified by name."
    return 1
  fi
  code=$(curl --silent --show-error --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    -X DELETE -o /tmp/hcp-agent-nutanix-dns-resource.json -w '%{http_code}' \
    "$NUTANIX_PC_URL/api/nutanix/v3/$kind/$uuid")
  if [[ "$code" != 200 && "$code" != 202 && "$code" != 204 && "$code" != 404 ]]; then
    echo "Nutanix refused to delete run-owned $kind $uuid (HTTP $code)."
    return 1
  fi
  if [[ "$code" != 404 && "$code" != 204 ]]; then
    response=$(cat /tmp/hcp-agent-nutanix-dns-resource.json)
    wait_for_dns_task "$(jq -r '.status.execution_context.task_uuid // empty' <<<"$response")"
  fi
  if ! wait_for_uuid_absent "$kind" "$uuid"; then
    echo "Run-owned Nutanix $kind $uuid is still present."
    return 1
  fi
}

while IFS= read -r uuid; do
  [[ -n "$uuid" ]] || continue
  if [[ ! "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || ! wait_for_uuid_absent vms "$uuid"; then
    echo "Nutanix VM UUID $uuid is still present or its deletion could not be verified for lease $lease_resource."
    worker_cleanup_failed=true
  fi
done < "$SHARED_DIR/vm_uuids.txt"

if [[ -s "$SHARED_DIR/image_uuid.txt" ]]; then
  image_uuid=$(cat "$SHARED_DIR/image_uuid.txt")
  if [[ ! "$image_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || ! wait_for_uuid_absent images "$image_uuid"; then
    echo "Nutanix image UUID $image_uuid is still present or its deletion could not be verified for lease $lease_resource."
    worker_cleanup_failed=true
  fi
fi

restore_dns_dhcp
delete_dns_resource vms "$SHARED_DIR/nutanix_dns_vm_uuid" "$SHARED_DIR/nutanix_dns_vm_name"
delete_dns_resource images "$SHARED_DIR/nutanix_dns_image_uuid" "$SHARED_DIR/nutanix_dns_image_name"

if [[ "$management_cleanup_failed" == "true" || "$worker_cleanup_failed" == "true" ]]; then
  echo "Run-owned management or worker resources remain or could not be verified for lease $lease_resource; DNS DHCP was restored and the helper VM was removed."
  exit 1
fi

rm -f "$SHARED_DIR/nutanix_context.sh" "$SHARED_DIR/nutanix_pull_secret_created"
rm -f "$SHARED_DIR/nutanix_dns_vm_name" "$SHARED_DIR/nutanix_dns_vm_uuid" \
  "$SHARED_DIR/nutanix_dns_image_name" "$SHARED_DIR/nutanix_dns_image_uuid" \
  "$SHARED_DIR/nutanix_dns_ip" "$SHARED_DIR/nutanix_dns_dhcp_state.json" \
  "$SHARED_DIR/nutanix_dns_dhcp_state.json.tmp"
rm -rf /tmp/hcp-agent-nutanix
printf "Deleted this run's Nutanix resources for lease %s; CI-operator releases the lease after the workflow.\n" "$lease_resource"
