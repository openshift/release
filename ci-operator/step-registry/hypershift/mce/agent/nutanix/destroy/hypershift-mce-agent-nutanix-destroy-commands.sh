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
  if [[ -s "$SHARED_DIR/nutanix_worker_names" || -s "$SHARED_DIR/nutanix_image_name" || -s "$SHARED_DIR/nutanix_infraenv_name" ]]; then
    echo "Nutanix resources may exist but the private Nutanix context is unavailable; cleanup cannot be verified for $lease_resource."
    exit 1
  fi
  exit 0
fi

source "$context_file"
if [[ ! -s "$SHARED_DIR/cluster-name" ]]; then
  exit 0
fi
CLUSTER_NAME=$(cat "$SHARED_DIR/cluster-name")
RUN_LABEL_KEY=ci.openshift.io/hcp-agent-nutanix-run
export KUBECONFIG="$SHARED_DIR/kubeconfig"
management_cleanup_failed=false

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
    exit 1
  fi
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
  ANSIBLE_ROLES_PATH="$ANSIBLE_FILES_DIR/roles" ansible-playbook -i localhost, "$cleanup_playbook"
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

while IFS= read -r uuid; do
  [[ -n "$uuid" ]] || continue
  if [[ ! "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || ! wait_for_uuid_absent vms "$uuid"; then
    echo "Nutanix VM UUID $uuid is still present or its deletion could not be verified for lease $lease_resource."
    exit 1
  fi
done < "$SHARED_DIR/vm_uuids.txt"

if [[ -s "$SHARED_DIR/image_uuid.txt" ]]; then
  image_uuid=$(cat "$SHARED_DIR/image_uuid.txt")
  if [[ ! "$image_uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || ! wait_for_uuid_absent images "$image_uuid"; then
    echo "Nutanix image UUID $image_uuid is still present or its deletion could not be verified for lease $lease_resource."
    exit 1
  fi
fi

if [[ "$management_cleanup_failed" == "true" ]]; then
  echo "Nutanix resources are gone, but run-owned management resources remain or could not be verified for lease $lease_resource."
  exit 1
fi

rm -f "$SHARED_DIR/nutanix_context.sh" "$SHARED_DIR/nutanix_pull_secret_created"
rm -rf /tmp/hcp-agent-nutanix
printf "Deleted this run's Nutanix resources for lease %s; CI-operator releases the lease after the workflow.\n" "$lease_resource"
