#!/bin/bash

set -euo pipefail
tracing_enabled=false
if [[ $- == *x* ]]; then tracing_enabled=true; fi
# Prism credentials are used throughout VM discovery, deletion, and verification.
set +x

context_file="$SHARED_DIR/nutanix_context.sh"
trap 'status=$?; if (( status == 0 )) && [[ ! -e "$SHARED_DIR/nutanix_ingress_tunnel_state.json" ]]; then rm -f "$context_file" "$SHARED_DIR/nutanix_ingress_vip"; fi' EXIT

if [[ -z "${NUTANIX_QUOTA_SLICE:-}" ]]; then
  echo "NUTANIX_QUOTA_SLICE is required from the workflow lease."
  exit 1
fi
lease_resource=${NUTANIX_QUOTA_SLICE}

if [[ ! -s "$context_file" ]]; then
  if [[ -s "$SHARED_DIR/nutanix_worker_names" || -s "$SHARED_DIR/nutanix_image_name" ||
        -s "$SHARED_DIR/nutanix_infraenv_name" || -s "$SHARED_DIR/nutanix_worker_macs.json" ||
        -s "$SHARED_DIR/nutanix_ingress_tunnel_state.json" ]]; then
    echo "Nutanix resources may exist but the private Nutanix context is unavailable; cleanup cannot be verified for $lease_resource."
    exit 1
  fi
  exit 0
fi

# shellcheck source=/dev/null
source "$context_file"
if [[ ! -s "$SHARED_DIR/cluster-name" ]]; then
  if [[ -s "$SHARED_DIR/nutanix_worker_macs.json" || -s "$SHARED_DIR/nutanix_worker_names" ||
        -s "$SHARED_DIR/nutanix_infraenv_name" ]]; then
    echo "Nutanix resources may exist but the HostedCluster name is unavailable."
    exit 1
  fi
  exit 0
fi
CLUSTER_NAME=$(cat "$SHARED_DIR/cluster-name")
if [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9-]+$ ]]; then
  echo "The recorded HostedCluster name is invalid."
  exit 1
fi

# The InfraEnv step records worker names and MACs before the workers step can
# create VMs. Recover exact run-owned names when worker provisioning failed or
# its UUID records were never returned to the CI shared directory.
worker_macs_file="$SHARED_DIR/nutanix_worker_macs.json"
worker_names_file="$SHARED_DIR/nutanix_worker_names"
if [[ -e "$worker_macs_file" ]]; then
  if [[ ! -s "$worker_macs_file" ]] || ! jq -e --arg cluster "$CLUSTER_NAME" '
    . as $workers |
    ($workers | type) == "array" and
    ($workers | length) > 0 and
    all($workers | to_entries[];
      .value.name == ($cluster + "-worker-" + (.key | tostring)) and
      (.value.mac // "" | test("^02(:[0-9a-f]{2}){5}$"))) and
    ([$workers[].mac] | unique | length) == ($workers | length)
  ' "$worker_macs_file" >/dev/null; then
    echo "The recorded Nutanix worker MAC reservations are invalid; refusing VM cleanup."
    exit 1
  fi
  if [[ -s "$worker_names_file" ]]; then
    if ! cmp -s "$worker_names_file" <(jq -r '.[].name' "$worker_macs_file"); then
      echo "The recorded Nutanix worker names do not match the MAC reservations."
      exit 1
    fi
  else
    jq -r '.[].name' "$worker_macs_file" > "$worker_names_file"
  fi
fi

image_name_file="$SHARED_DIR/nutanix_image_name"
if [[ -s "$SHARED_DIR/nutanix_infraenv_name" ]]; then
  infraenv_name=$(<"$SHARED_DIR/nutanix_infraenv_name")
  if [[ "$infraenv_name" != "$CLUSTER_NAME-nutanix" ]]; then
    echo "The recorded Nutanix InfraEnv name does not match this HostedCluster."
    exit 1
  fi
  expected_image_name="$infraenv_name.iso"
  if [[ -s "$image_name_file" ]]; then
    if [[ "$(<"$image_name_file")" != "$expected_image_name" ]]; then
      echo "The recorded Nutanix image name does not match this InfraEnv."
      exit 1
    fi
  else
    printf '%s\n' "$expected_image_name" > "$image_name_file"
  fi
fi

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
  if [[ -s "$SHARED_DIR/nutanix_worker_macs.json" ]]; then
    oc delete nmstateconfigs -n "$AGENT_NAMESPACE" -l "$RUN_LABEL_KEY=$CLUSTER_NAME" \
      --ignore-not-found --wait=true --timeout=2m || true
    if ! remaining_nmstateconfigs=$(oc get nmstateconfigs -n "$AGENT_NAMESPACE" \
      -l "$RUN_LABEL_KEY=$CLUSTER_NAME" -o name 2>/dev/null); then
      management_cleanup_failed=true
    elif [[ -n "$remaining_nmstateconfigs" ]]; then
      echo "Run-owned NMStateConfigs remain in namespace $AGENT_NAMESPACE."
      management_cleanup_failed=true
    fi
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

# Prism v3 list responses are paginated. Check every page before deciding that
# a run-owned resource was never created after a lost provisioning response.
find_prism_uuid_by_name() {
  local endpoint=$1 kind=$2 name=$3 offset=0 page_size=500 response total count page_matches uuid
  local -a matches=()
  while :; do
    response=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
      -H 'Content-Type: application/json' -X POST "$NUTANIX_PC_URL/api/nutanix/v3/$endpoint/list" \
      --data "$(jq -nc --arg kind "$kind" --argjson offset "$offset" --argjson length "$page_size" \
        '{kind:$kind,offset:$offset,length:$length}')") || return 1
    total=$(jq -er '.metadata.total_matches | select(type == "number" and . >= 0)' <<<"$response") || return 1
    count=$(jq -er '.entities | if type == "array" then length else error("Missing Prism entities") end' <<<"$response") || return 1
    if (( offset + count > total || (count == 0 && offset < total) )); then
      echo "Prism returned an incomplete $endpoint page; cleanup cannot be verified." >&2
      return 1
    fi
    page_matches=$(jq -r --arg name "$name" '.entities[] | select(.spec.name == $name) | .metadata.uuid' <<<"$response") || return 1
    while IFS= read -r uuid; do
      [[ -n "$uuid" ]] && matches+=("$uuid")
    done <<<"$page_matches"
    offset=$((offset + count))
    (( offset >= total )) && break
  done
  if (( ${#matches[@]} > 1 )); then
    echo "More than one Prism $kind has the exact run-owned name $name; refusing broad cleanup." >&2
    return 1
  fi
  if (( ${#matches[@]} == 1 )); then
    [[ "${matches[0]}" =~ ^[0-9a-fA-F-]{36}$ ]] || return 1
    printf '%s\n' "${matches[0]}"
  fi
}

recorded_vm_count=$(awk '/^[0-9a-fA-F-]{36}$/ { count++ } END { print count + 0 }' "$SHARED_DIR/vm_uuids.txt")
expected_vm_count=0
if [[ -s "$SHARED_DIR/nutanix_worker_names" ]]; then
  expected_vm_count=$(awk 'NF { count++ } END { print count + 0 }' "$SHARED_DIR/nutanix_worker_names")
fi
if (( recorded_vm_count < expected_vm_count )); then
  while IFS= read -r vm_name; do
    [[ -n "$vm_name" ]] || continue
    uuid=$(find_prism_uuid_by_name vms vm "$vm_name") || exit 1
    if [[ -n "$uuid" ]] && ! grep -Fxq "$uuid" "$SHARED_DIR/vm_uuids.txt"; then
      printf '%s\n' "$uuid" >> "$SHARED_DIR/vm_uuids.txt"
    fi
  done < "$SHARED_DIR/nutanix_worker_names"
fi

if [[ -s "$SHARED_DIR/nutanix_image_name" && ! "$(cat "$SHARED_DIR/image_uuid.txt")" =~ ^[0-9a-fA-F-]{36}$ ]]; then
  image_name=$(cat "$SHARED_DIR/nutanix_image_name")
  uuid=$(find_prism_uuid_by_name images image "$image_name") || exit 1
  if [[ -n "$uuid" ]]; then
    printf '%s\n' "$uuid" > "$SHARED_DIR/image_uuid.txt"
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
  cleanup_vars=$(jq -Rs --arg image_uuid "$(cat "$SHARED_DIR/image_uuid.txt")" \
    '{vm_uuids: split("\n") | map(select(length > 0)), image_uuid: $image_uuid}' "$SHARED_DIR/vm_uuids.txt")
  WORK_DIR=/tmp/hcp-agent-nutanix
  mkdir -p "$WORK_DIR"
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
  ANSIBLE_COLLECTIONS_PATH="/output/.ansible/collections:/usr/share/ansible/collections${ANSIBLE_COLLECTIONS_PATH:+:$ANSIBLE_COLLECTIONS_PATH}" \
    HOME="$WORK_DIR" ANSIBLE_LOCAL_TEMP=/tmp ANSIBLE_REMOTE_TEMP=/tmp \
    ANSIBLE_ROLES_PATH="$ANSIBLE_FILES_DIR/roles" \
    ansible-playbook -i localhost, --extra-vars "$cleanup_vars" "$cleanup_playbook"
fi

function wait_for_uuid_absent() {
  local endpoint=$1
  local uuid=$2
  local code
  for ((attempt = 1; attempt <= 20; attempt++)); do
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

rm -f "$SHARED_DIR/nutanix_pull_secret_created"
rm -rf /tmp/hcp-agent-nutanix
if [[ -e "$SHARED_DIR/nutanix_ingress_tunnel_state.json" ]]; then
  touch "$SHARED_DIR/nutanix_destroy_complete"
else
  rm -f "$SHARED_DIR/nutanix_context.sh" "$SHARED_DIR/nutanix_ingress_vip"
fi
printf "Deleted this run's Nutanix resources for lease %s; CI-operator releases the lease after the workflow.\n" "$lease_resource"
if [[ "$tracing_enabled" == true ]]; then set -x; fi
