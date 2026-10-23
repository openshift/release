#!/bin/bash

set -euo pipefail

export KUBECONFIG="$SHARED_DIR/kubeconfig"
set +x
source "$SHARED_DIR/nutanix_context.sh"
CLUSTER_NAME=$(cat "$SHARED_DIR/cluster-name")
INFRAENV_NAME=$(cat "$SHARED_DIR/nutanix_infraenv_name")
AGENT_NAMESPACE=$(cat "$SHARED_DIR/nutanix_agent_namespace")
RUN_LABEL_KEY=ci.openshift.io/hcp-agent-nutanix-run
IMAGE_NAME="$INFRAENV_NAME.iso"
WORK_DIR=/tmp/hcp-agent-nutanix
if [[ ! "${NUTANIX_WORKERS:-}" =~ ^[1-9][0-9]*$ ]]; then
  echo "NUTANIX_WORKERS must be a positive integer."
  exit 1
fi
if [[ -n "${AGENT_QE_INFRA_ANSIBLE_DIR:-}" ]]; then
  ANSIBLE_FILES_DIR=${AGENT_QE_INFRA_ANSIBLE_DIR}
else
  ANSIBLE_FILES_DIR=/go/src/github.com/openshift-eng/agent-qe-infra/ansible-files
fi

if [[ ! -f "$ANSIBLE_FILES_DIR/vars/ci_nutanix.yml" || ! -d "$ANSIBLE_FILES_DIR/roles/nutanix/upload_image" ]]; then
  echo "agent-qe-infra/ansible-files was not found at $ANSIBLE_FILES_DIR; configure it as a Prow extra ref."
  exit 1
fi

function gather_failure_diagnostics() {
  local status=$?
  if (( status != 0 )); then
    set +e
    mkdir -p "$ARTIFACT_DIR"
    oc --kubeconfig="$SHARED_DIR/kubeconfig" get infraenv "$INFRAENV_NAME" -n "$AGENT_NAMESPACE" -o json | jq '{metadata:{name:.metadata.name,namespace:.metadata.namespace,labels:.metadata.labels},spec:{cpuArchitecture:.spec.cpuArchitecture,pullSecretRef:.spec.pullSecretRef,proxy:.spec.proxy},status:{conditions:.status.conditions}}' > "$ARTIFACT_DIR/nutanix-infraenv.json" 2>&1
    oc --kubeconfig="$SHARED_DIR/kubeconfig" get agents -n "$AGENT_NAMESPACE" -o yaml > "$ARTIFACT_DIR/nutanix-agents.yaml" 2>&1
    oc --kubeconfig="$SHARED_DIR/kubeconfig" get nodepool "$CLUSTER_NAME" -n local-cluster -o yaml > "$ARTIFACT_DIR/nutanix-nodepool.yaml" 2>&1
    oc --kubeconfig="$SHARED_DIR/kubeconfig" get hostedcluster "$CLUSTER_NAME" -n local-cluster -o yaml > "$ARTIFACT_DIR/nutanix-hostedcluster.yaml" 2>&1
  fi
  return "$status"
}
trap gather_failure_diagnostics EXIT

mkdir -p "$WORK_DIR"
reserved_macs_file="$SHARED_DIR/nutanix_worker_macs.json"
if [[ ! -s "$reserved_macs_file" ]] || ! jq -e --arg cluster "$CLUSTER_NAME" --argjson count "$NUTANIX_WORKERS" '
  type == "array" and length == $count and
  ([.[].mac] | unique | length) == $count and
  all(to_entries[]; .value.name == ($cluster + "-worker-" + (.key | tostring)) and
    (.value.mac | test("^02(:[0-9a-f]{2}){5}$")))
' "$reserved_macs_file" >/dev/null; then
  echo "The InfraEnv did not reserve exactly $NUTANIX_WORKERS distinct worker MACs for this run."
  exit 1
fi
jq -r '.[].name' "$reserved_macs_file" > "$SHARED_DIR/hostnames.txt"
cp "$SHARED_DIR/hostnames.txt" "$SHARED_DIR/nutanix_worker_names"
printf '%s\n' "$IMAGE_NAME" > "$SHARED_DIR/nutanix_image_name"
: > "$SHARED_DIR/vm_uuids.txt"
: > "$SHARED_DIR/image_uuid.txt"
iso_url=$(oc get infraenv "$INFRAENV_NAME" -n "$AGENT_NAMESPACE" -o go-template='{{with .status.isoDownloadURL}}{{.}}{{end}}')
if [[ -z "$iso_url" ]]; then
  echo "InfraEnv $INFRAENV_NAME has no ISO download URL."
  exit 1
fi
if [[ ! -s "$SHARED_DIR/nutanix_proxy_url" ]]; then
  echo "The baremetal Squid proxy URL is not available."
  exit 1
fi
proxy_url=$(<"$SHARED_DIR/nutanix_proxy_url")
curl --fail --location --silent --show-error --insecure \
  --proxy "$proxy_url" --noproxy '' "$iso_url" -o "$WORK_DIR/$IMAGE_NAME"

export WORK_DIR AGENT_IMAGE="$IMAGE_NAME" SHARED_DIR
export NUTANIX_HOST NUTANIX_PORT NUTANIX_USERNAME NUTANIX_PASSWORD NUTANIX_PC_URL
export PE_HOST PE_PORT PE_USERNAME PE_PASSWORD PE_UUID PE_NAME PE_STORAGE_CONTAINER SUBNET_UUID
unset RENDEZVOUS_IP

playbook="$WORK_DIR/provision.yml"
cat > "$playbook" <<EOF
- name: Provision only the HostedCluster Agent workers
  hosts: localhost
  gather_facts: false
  connection: local
  vars_files:
    - "$ANSIBLE_FILES_DIR/vars/ci_nutanix.yml"
  vars:
    vm_memory_gb: 16
    vm_disk_size_gb: 120
    worker_macs: "{{ lookup('file', lookup('env', 'SHARED_DIR') + '/nutanix_worker_macs.json') | from_json }}"
  module_defaults:
    group/nutanix.ncp.ntnx:
      nutanix_username: "{{ lookup('env', 'NUTANIX_USERNAME') }}"
      nutanix_password: "{{ lookup('env', 'NUTANIX_PASSWORD') }}"
      nutanix_host: "{{ lookup('env', 'NUTANIX_HOST') }}"
      validate_certs: false
  roles:
    - "$ANSIBLE_FILES_DIR/roles/nutanix/upload_image"
  tasks:
    - name: Provision workers with their InfraEnv NMStateConfig MACs
      nutanix.ncp.ntnx_vms:
        name: "{{ worker.name }}"
        vcpus: 8
        cores_per_vcpu: 1
        memory_gb: "{{ vm_memory_gb }}"
        cluster:
          name: "{{ cluster_name }}"
        disks:
          - type: DISK
            size_gb: "{{ vm_disk_size_gb }}"
            storage_container:
              name: "{{ vm_container }}"
            bus: SCSI
          - type: CDROM
            clone_image:
              name: "{{ vm_clone_image_name }}"
            bus: IDE
        networks:
          - subnet:
              uuid: "{{ vm_network_uuid }}"
            mac_address: "{{ worker.mac }}"
        boot_config:
          boot_order:
            - DISK
            - CDROM
        state: present
      loop: "{{ worker_macs }}"
      loop_control:
        loop_var: worker
      async: 600
      poll: 0
      vars:
        ansible_async_dir: "{{ work_dir }}/.ansible_async"
      no_log: true
      register: create_vm_results
    - name: Wait for worker provisioning
      async_status:
        jid: "{{ item.ansible_job_id }}"
      loop: "{{ create_vm_results.results }}"
      register: job_result
      until: job_result.finished
      retries: 20
      delay: 15
      vars:
        ansible_async_dir: "{{ work_dir }}/.ansible_async"
      no_log: true
      when: item.ansible_job_id is defined
    - name: Record worker UUIDs for deprovisioning
      copy:
        content: "{{ job_result.results | map(attribute='vm_uuid') | join('\n') }}"
        dest: "{{ shared_dir }}/vm_uuids.txt"
      no_log: true
EOF

ansible_status=0
ANSIBLE_COLLECTIONS_PATH="/output/.ansible/collections:/usr/share/ansible/collections${ANSIBLE_COLLECTIONS_PATH:+:$ANSIBLE_COLLECTIONS_PATH}" \
  HOME="$WORK_DIR" ANSIBLE_LOCAL_TEMP=/tmp ANSIBLE_REMOTE_TEMP=/tmp \
  ANSIBLE_ROLES_PATH="$ANSIBLE_FILES_DIR/roles" \
  ansible-playbook -i localhost, "$playbook" || ansible_status=$?

if [[ -s "$SHARED_DIR/vm_uuids.txt" && -n "$(tail -c 1 "$SHARED_DIR/vm_uuids.txt")" ]]; then
  printf '\n' >> "$SHARED_DIR/vm_uuids.txt"
fi

function recover_recorded_ids() {
  local response name uuid
  response=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    -H 'Content-Type: application/json' -X POST "$NUTANIX_PC_URL/api/nutanix/v3/vms/list" \
    --data '{"kind":"vm","length":500}')
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    uuid=$(jq -r --arg name "$name" '[.entities[] | select(.spec.name == $name) | .metadata.uuid] | unique | if length == 1 then .[0] else empty end' <<<"$response")
    if [[ -n "$uuid" ]] && ! grep -Fxq "$uuid" "$SHARED_DIR/vm_uuids.txt"; then
      printf '%s\n' "$uuid" >> "$SHARED_DIR/vm_uuids.txt"
    fi
  done < "$SHARED_DIR/nutanix_worker_names"
  if [[ ! -s "$SHARED_DIR/image_uuid.txt" ]]; then
    response=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
      -H 'Content-Type: application/json' -X POST "$NUTANIX_PC_URL/api/nutanix/v3/images/list" \
      --data '{"kind":"image","length":500}')
    uuid=$(jq -r --arg name "$IMAGE_NAME" '[.entities[] | select(.spec.name == $name) | .metadata.uuid] | unique | if length == 1 then .[0] else empty end' <<<"$response")
    [[ -z "$uuid" ]] || printf '%s\n' "$uuid" > "$SHARED_DIR/image_uuid.txt"
  fi
}

if (( ansible_status != 0 )); then
  recover_recorded_ids || true
  exit "$ansible_status"
fi

recover_recorded_ids
if [[ $(wc -l < "$SHARED_DIR/vm_uuids.txt") -ne "$NUTANIX_WORKERS" || ! -s "$SHARED_DIR/image_uuid.txt" ]]; then
  echo "Nutanix provisioning did not record exactly $NUTANIX_WORKERS worker UUIDs and one image UUID."
  exit 1
fi

map_file="$SHARED_DIR/nutanix_worker_vms.tsv"
: > "$map_file"
while IFS=$'\t' read -r name expected_mac && IFS= read -r uuid <&3; do
  vm_json=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    "$NUTANIX_PC_URL/api/nutanix/v3/vms/$uuid")
  mac=$(jq -er --arg subnet "$SUBNET_UUID" '[.spec.resources.nic_list[]? |
    select(.subnet_reference.uuid == $subnet) | .mac_address // empty] |
    map(ascii_downcase) | unique |
    if length == 1 then .[0] else error("VM NIC MAC is missing or ambiguous") end' <<<"$vm_json")
  if [[ "$mac" != "$expected_mac" ]]; then
    echo "Nutanix VM $name did not receive its reserved NIC MAC $expected_mac."
    exit 1
  fi
  printf '%s\t%s\t%s\n' "$name" "$uuid" "$mac" >> "$map_file"
done 3< "$SHARED_DIR/vm_uuids.txt" < <(jq -r '.[] | [.name, .mac] | @tsv' "$reserved_macs_file")

function matching_agents() {
  oc get agents -n "$AGENT_NAMESPACE" -o json | jq -r --arg infraenv "$INFRAENV_NAME" \
    '.items[] | select(.metadata.labels["infraenvs.agent-install.openshift.io"] == $infraenv) | .metadata.name'
}

agent_deadline=$((SECONDS + 3600))
agents=""
while (( SECONDS < agent_deadline )); do
  agents=$(matching_agents)
  agent_count=$(awk 'NF { count++ } END { print count + 0 }' <<<"$agents")
  if (( agent_count > NUTANIX_WORKERS )); then
    echo "InfraEnv $INFRAENV_NAME selected $agent_count Agents; expected exactly $NUTANIX_WORKERS."
    exit 1
  fi
  if (( agent_count == NUTANIX_WORKERS )); then
    break
  fi
  echo "Waiting for $NUTANIX_WORKERS Agents associated with InfraEnv $INFRAENV_NAME; found $agent_count."
  sleep 30
done
if [[ $(awk 'NF { count++ } END { print count + 0 }' <<<"$agents") -ne "$NUTANIX_WORKERS" ]]; then
  echo "Timed out waiting for the $NUTANIX_WORKERS InfraEnv Agents."
  exit 1
fi

# TODO: This should be checked after approving them.
for agent in $agents; do
  oc wait agent "$agent" -n "$AGENT_NAMESPACE" --for=condition=Validated --timeout=20m
  agent_json=$(oc get agent "$agent" -n "$AGENT_NAMESPACE" -o json)
  if ! jq -e '
    [.status.validationsInfo.network[]? |
      select(.id == "api-domain-name-resolved-correctly" or
             .id == "api-int-domain-name-resolved-correctly" or
             .id == "apps-domain-name-resolved-correctly" or
             .id == "ignition-downloadable")] |
    length == 4 and all(.[]; .status == "success")
  ' <<<"$agent_json" >/dev/null; then
    echo "Agent $agent has not passed API, API-int, apps DNS, and ignition-downloadable validations."
    jq -r '.status.validationsInfo.network[]? | select(.id | test("domain-name-resolved-correctly|ignition-downloadable")) | "\(.id): \(.status): \(.message)"' <<<"$agent_json"
    exit 1
  fi
done

map_file="$SHARED_DIR/nutanix_agent_vm_mapping.tsv"
: > "$map_file"
mapped_agent_names=""
mapped_count=0
while IFS=$'\t' read -r vm_name _ vm_mac; do
  vm_mac_normalized=$(tr -d ':' <<<"$vm_mac" | tr '[:upper:]' '[:lower:]')
  matched_agent=""
  for agent in $agents; do
    inventory_macs=$(oc get agent "$agent" -n "$AGENT_NAMESPACE" -o json | jq -r '.status.inventory.interfaces[]?.macAddress // empty' | tr '[:upper:]' '[:lower:]' | tr -d ':')
    if grep -Fxq "$vm_mac_normalized" <<<"$inventory_macs"; then
      if [[ -n "$matched_agent" ]]; then
        echo "More than one Agent reports the MAC address $vm_mac."
        exit 1
      fi
      matched_agent=$agent
    fi
  done
  if [[ -z "$matched_agent" ]] || grep -Fxq "$matched_agent" <<<"$mapped_agent_names"; then
    echo "Nutanix VM $vm_name ($vm_mac) did not map to exactly one distinct InfraEnv Agent."
    exit 1
  fi
  mapped_agent_names=$(printf '%s\n%s' "$mapped_agent_names" "$matched_agent")
  mapped_count=$((mapped_count + 1))
  oc label agent "$matched_agent" -n "$AGENT_NAMESPACE" "$RUN_LABEL_KEY=$CLUSTER_NAME" --overwrite
  agent_hostname=$(oc get agent "$matched_agent" -n "$AGENT_NAMESPACE" -o jsonpath='{.status.inventory.hostname}')
  printf '%s\t%s\t%s\t%s\n' "$matched_agent" "$agent_hostname" "$vm_name" "$vm_mac" >> "$map_file"
done < "$SHARED_DIR/nutanix_worker_vms.tsv"

if [[ "$mapped_count" -ne "$NUTANIX_WORKERS" ]]; then
  echo "The run's $NUTANIX_WORKERS VM NICs did not map to $NUTANIX_WORKERS distinct Agents."
  exit 1
fi

selected_count=$(oc get agents -n "$AGENT_NAMESPACE" -l "$RUN_LABEL_KEY=$CLUSTER_NAME" --no-headers | wc -l)
if [[ "$selected_count" -ne "$NUTANIX_WORKERS" ]]; then
  echo "The run label matched $selected_count Agents; expected exactly $NUTANIX_WORKERS."
  exit 1
fi

nodepool_selector=$(jq -n --arg key "$RUN_LABEL_KEY" --arg value "$CLUSTER_NAME" \
  '{spec:{replicas:0,platform:{agent:{agentLabelSelector:{matchLabels:{($key):$value}}}}}}')
oc patch nodepool "$CLUSTER_NAME" -n local-cluster --type=merge -p "$nodepool_selector"
for agent in $agents; do
  oc patch agent "$agent" -n "$AGENT_NAMESPACE" --type=merge -p '{"spec":{"approved":true}}'
done
for agent in $agents; do oc wait agent "$agent" -n "$AGENT_NAMESPACE" --for=condition=RequirementsMet --timeout=20m; done

oc scale nodepool "$CLUSTER_NAME" -n local-cluster --replicas="$NUTANIX_WORKERS"
oc wait agents -n "$AGENT_NAMESPACE" -l "$RUN_LABEL_KEY=$CLUSTER_NAME" \
  --for=jsonpath='{.status.debugInfo.state}'=added-to-existing-cluster --timeout=60m

export KUBECONFIG="$SHARED_DIR/nested_kubeconfig"
node_deadline=$((SECONDS + 3600))
while (( SECONDS < node_deadline )); do
  nodes_json=$(oc get nodes -o json)
  node_count=$(jq '.items | length' <<<"$nodes_json")
  ready_count=$(jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$nodes_json")
  if (( node_count > NUTANIX_WORKERS )); then
    echo "The HostedCluster has $node_count Nodes; expected exactly $NUTANIX_WORKERS."
    exit 1
  fi
  if (( node_count == NUTANIX_WORKERS && ready_count == NUTANIX_WORKERS )); then
    break
  fi
  echo "Waiting for $NUTANIX_WORKERS Ready HostedCluster Nodes; found $ready_count/$node_count."
  sleep 30
done
if [[ "$node_count" -ne "$NUTANIX_WORKERS" || "$ready_count" -ne "$NUTANIX_WORKERS" ]]; then
  echo "Timed out waiting for all $NUTANIX_WORKERS HostedCluster worker Nodes to become Ready."
  exit 1
fi

proxy_json=$(oc get proxy cluster -o json)
expected_proxy=$(cat "$SHARED_DIR/nutanix_proxy_url")
jq -e --arg proxy "$expected_proxy" '.spec.httpProxy == $proxy and .spec.httpsProxy == $proxy' <<<"$proxy_json" >/dev/null
proxy_host=$(sed 's|^http://||' <<<"$expected_proxy" | sed 's|:[^:]*$||')
proxy_port=$(cut -d: -f3 <<<"$expected_proxy")
for node in $(oc get nodes -o jsonpath='{.items[*].metadata.name}'); do
  oc debug "node/$node" --quiet -- chroot /host /usr/bin/bash -c \
    "timeout 10 /usr/bin/bash -c '</dev/tcp/$proxy_host/$proxy_port'" >/dev/null
done

rm -f "$WORK_DIR/$IMAGE_NAME"
printf 'Provisioned %s run-owned Nutanix workers; Agents joined and guest Nodes are Ready.\n' "$NUTANIX_WORKERS"
