#!/bin/bash

set -euo pipefail

# OpenShift assigns an arbitrary UID, and OpenSSH requires a passwd entry for it.
if ! getent passwd "$(id -u)" >/dev/null; then
  /usr/local/bin/fix_uid.sh
fi

export KUBECONFIG="$SHARED_DIR/kubeconfig"
tracing_enabled=false
if [[ $- == *x* ]]; then tracing_enabled=true; fi
# Prism credentials and cluster/proxy data are used across worker provisioning.
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
if [[ ! "$CLUSTER_NAME" =~ ^[a-z0-9-]+$ ||
      "$INFRAENV_NAME" != "$CLUSTER_NAME-nutanix" ||
      ! "$AGENT_NAMESPACE" =~ ^[a-z0-9-]+$ ]]; then
  echo "The recorded HostedCluster, InfraEnv, or Agent namespace is invalid."
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

tunnel_state_file="$SHARED_DIR/nutanix_ingress_tunnel_state.json"
gateway_ssh_config="$SHARED_DIR/nutanix_ingress_tunnel_ssh_config"
if [[ ! -s "$tunnel_state_file" || ! -s "$gateway_ssh_config" ]] || ! jq -e \
  --arg lease "${NUTANIX_QUOTA_SLICE:-}" --arg subnet "$SUBNET_UUID" \
  '.stage == "ready" and .lease == $lease and .subnetUUID == $subnet' \
  "$tunnel_state_file" >/dev/null; then
  echo "The Nutanix ingress tunnel must be ready before worker boot."
  exit 1
fi
ssh -F "$gateway_ssh_config" nutanix-ingress-gateway \
  'sudo systemctl is-active --quiet hypershift-nutanix-ingress-firewall.service'

mkdir -p "$WORK_DIR"
worker_names_file="$SHARED_DIR/nutanix_worker_names"
expected_names_file="$WORK_DIR/expected-worker-names"
: > "$expected_names_file"
for ((worker_index = 0; worker_index < NUTANIX_WORKERS; worker_index++)); do
  printf '%s-worker-%s\n' "$CLUSTER_NAME" "$worker_index" >> "$expected_names_file"
done
if [[ -e "$worker_names_file" ]] && ! cmp -s "$expected_names_file" "$worker_names_file"; then
  echo "The recorded Nutanix worker names do not match this run."
  exit 1
fi
cp "$expected_names_file" "$worker_names_file"
cp "$worker_names_file" "$SHARED_DIR/hostnames.txt"
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
    worker_names: "{{ lookup('file', lookup('env', 'SHARED_DIR') + '/nutanix_worker_names').splitlines() }}"
  module_defaults:
    group/nutanix.ncp.ntnx:
      nutanix_username: "{{ lookup('env', 'NUTANIX_USERNAME') }}"
      nutanix_password: "{{ lookup('env', 'NUTANIX_PASSWORD') }}"
      nutanix_host: "{{ lookup('env', 'NUTANIX_HOST') }}"
      validate_certs: false
  roles:
    - "$ANSIBLE_FILES_DIR/roles/nutanix/upload_image"
  tasks:
    - name: Provision HostedCluster workers
      nutanix.ncp.ntnx_vms:
        name: "{{ worker }}"
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
        boot_config:
          boot_order:
            - DISK
            - CDROM
        state: present
      loop: "{{ worker_names }}"
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

mkdir -p "$ARTIFACT_DIR"
shape_file="$ARTIFACT_DIR/nutanix-worker-vm-shapes.jsonl"
: > "$shape_file"
while IFS= read -r uuid; do
  vm_json=$(curl --silent --show-error --fail --insecure --user "$NUTANIX_USERNAME:$NUTANIX_PASSWORD" \
    "$NUTANIX_PC_URL/api/nutanix/v3/vms/$uuid")
  name=$(jq -er '.spec.name' <<<"$vm_json")
  if ! grep -Fxq "$name" "$worker_names_file"; then
    echo "Nutanix VM $uuid does not have one of this run's worker names."
    exit 1
  fi
  if ! jq -e --arg subnet "$SUBNET_UUID" \
    '[.spec.resources.nic_list[]? | select(.subnet_reference.uuid == $subnet)] | length == 1' \
    <<<"$vm_json" >/dev/null; then
    echo "Nutanix VM $name does not have exactly one NIC on the worker subnet."
    exit 1
  fi
  shape=$(jq -c '{sockets:.status.resources.num_sockets,
    coresPerSocket:.status.resources.num_vcpus_per_socket,
    memoryMiB:.status.resources.memory_size_mib,
    diskMiB:[.status.resources.disk_list[]? |
      select(.device_properties.device_type == "DISK") | .disk_size_mib]}' <<<"$vm_json")
  if ! jq -e '.sockets == 8 and .coresPerSocket == 1 and
    .memoryMiB == 16384 and .diskMiB == [122880]' <<<"$shape" >/dev/null; then
    printf 'Nutanix VM %s has an unexpected CPU, memory, or disk shape: %s\n' "$name" "$shape"
    exit 1
  fi
  jq -cn --arg name "$name" --arg uuid "$uuid" --argjson shape "$shape" \
    '$shape + {name:$name,uuid:$uuid}' >> "$shape_file"
done < "$SHARED_DIR/vm_uuids.txt"
if ! cmp -s <(sort "$worker_names_file") <(jq -r '.name' "$shape_file" | sort); then
  echo "The provisioned Nutanix VMs do not match this run's worker names."
  exit 1
fi

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

for agent in $agents; do
  agent_json=$(oc get agent "$agent" -n "$AGENT_NAMESPACE" -o json)
  if ! jq -e --arg infraenv "$INFRAENV_NAME" --arg run_key "$RUN_LABEL_KEY" \
    --arg cluster "$CLUSTER_NAME" '
    .metadata.labels["infraenvs.agent-install.openshift.io"] == $infraenv and
    ((.metadata.labels[$run_key] // $cluster) == $cluster)
  ' <<<"$agent_json" >/dev/null; then
    echo "Agent $agent does not belong to this run's InfraEnv."
    exit 1
  fi
  oc label agent "$agent" -n "$AGENT_NAMESPACE" "$RUN_LABEL_KEY=$CLUSTER_NAME" --overwrite
done

selected_agents=$(oc get agents -n "$AGENT_NAMESPACE" -l "$RUN_LABEL_KEY=$CLUSTER_NAME" -o json)
if ! jq -e --arg infraenv "$INFRAENV_NAME" --argjson count "$NUTANIX_WORKERS" '
  (.items | length) == $count and
  all(.items[]; .metadata.labels["infraenvs.agent-install.openshift.io"] == $infraenv)
' <<<"$selected_agents" >/dev/null; then
  echo "The run label did not select exactly $NUTANIX_WORKERS Agents from this InfraEnv."
  exit 1
fi

nodepool_selector=$(jq -n --arg key "$RUN_LABEL_KEY" --arg value "$CLUSTER_NAME" \
  '{spec:{replicas:0,platform:{agent:{agentLabelSelector:{matchLabels:{($key):$value}}}}}}')
oc patch nodepool "$CLUSTER_NAME" -n local-cluster --type=merge -p "$nodepool_selector"
# The Agent provider does not copy ignition.proxy from HyperShift user-data; Assisted Service
# regenerates the disk-boot pointer, so restore the proxy before the Agents install.
ignition_overrides=$(jq -nc --arg proxy "$proxy_url" \
  '{ignition:{version:"3.2.0",proxy:{httpProxy:$proxy,httpsProxy:$proxy}}}')
agent_patch=$(jq -nc --arg overrides "$ignition_overrides" \
  '{spec:{approved:true,ignitionConfigOverrides:$overrides}}')
for agent in $agents; do
  oc patch agent "$agent" -n "$AGENT_NAMESPACE" --type=merge -p "$agent_patch"
  if ! oc get agent "$agent" -n "$AGENT_NAMESPACE" -o json | jq -e --arg overrides "$ignition_overrides" \
    '.spec.approved == true and .spec.ignitionConfigOverrides == $overrides' >/dev/null; then
    echo "Agent $agent did not retain its Ignition proxy override."
    exit 1
  fi
done
# The NodePool must be scaled first otherwise the api domain conditions do not appear.
oc scale nodepool "$CLUSTER_NAME" -n local-cluster --replicas="$NUTANIX_WORKERS"
validation_deadline=$((SECONDS + 1200))
for agent in $agents; do
  while :; do
    agent_json=$(oc get agent "$agent" -n "$AGENT_NAMESPACE" -o json)
    if jq -e '
      [.status.validationsInfo.network[]? |
        select(.id == "api-domain-name-resolved-correctly" or
               .id == "api-int-domain-name-resolved-correctly" or
               .id == "apps-domain-name-resolved-correctly" or
               .id == "ignition-downloadable")] |
      length == 4 and all(.[]; .status == "success")
    ' <<<"$agent_json" >/dev/null; then
      break
    fi
    if (( SECONDS >= validation_deadline )); then
      echo "Agent $agent has not passed API, API-int, apps DNS, and ignition-downloadable validations."
      jq -r '.status.validationsInfo.network[]? | select(.id | test("domain-name-resolved-correctly|ignition-downloadable")) | "\(.id): \(.status): \(.message)"' <<<"$agent_json"
      exit 1
    fi
    sleep 30
  done
done
for agent in $agents; do
  oc wait agent "$agent" -n "$AGENT_NAMESPACE" --for=condition=Validated --timeout=20m
  oc wait agent "$agent" -n "$AGENT_NAMESPACE" --for=condition=RequirementsMet --timeout=20m
done

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
if [[ "$tracing_enabled" == true ]]; then set -x; fi
