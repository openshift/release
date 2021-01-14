#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

export KUBECONFIG=${SHARED_DIR}/kubeconfig
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
AWS_REGION="$(oc get -o jsonpath='{.status.platformStatus.aws.region}' infrastructure cluster)"
export AWS_REGION

export SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
export PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

cat > create-machines.yaml <<-'EOF'
---
- name: Create AWS instances using machine sets
  hosts: localhost
  connection: local

  vars:
    aws_region: "{{ lookup('env', 'AWS_REGION') }}"
    cluster_dir: "{{ lookup('env', 'SHARED_DIR') }}"
    platform_type: "rhel"
    platform_version: "7.9"
    platform_type_dict:
      rhel:
        username: "ec2-user"
        owners: "309956199498"  # Red Hat, Inc.
        filters:
          name: "RHEL-{{ platform_version }}*Hourly*"
          architecture: "x86_64"
    kubeconfig_path: "{{ lookup('env', 'KUBECONFIG') }}"
    pull_secret_path: "{{ lookup('env', 'PULL_SECRET_PATH') }}"
    private_key_path: "{{ lookup('env', 'SSH_PRIV_KEY_PATH') }}"
    new_workers_list: []

  tasks:
  - name: Retreive platform AMI list
    ec2_ami_info:
      region: "{{ aws_region }}"
      owners: "{{ platform_type_dict[platform_type].owners }}"
      filters: "{{ platform_type_dict[platform_type].filters }}"
    register: ec2_ami_facts_results

  - name: Set aws_ami to most recent image
    set_fact:
      aws_ami: "{{ ec2_ami_facts_results.images[-1].image_id }}"

  - name: Get existing worker machinesets
    command: >
      oc get machinesets
      --kubeconfig={{ kubeconfig_path }}
      --namespace=openshift-machine-api
      --output=json
    register: machineset
    until:
    - machineset.stdout != ''
    changed_when: false

  - include_tasks: create_machineset.yaml
    loop: "{{ (machineset.stdout | from_json)['items'] }}"
    loop_control:
      loop_var: machineset_obj
    when:
    - machineset_obj.status.replicas is defined
    - machineset_obj.status.replicas != 0

  - name: Fail if new_workers_list is empty
    fail:
      msg: >
        No new_workers created, check replica count for existing machinesets.
    when:
    - new_workers_list | length == 0

  - name: Get ssh bastion address
    command: >
      oc get service ssh-bastion
      --kubeconfig={{ kubeconfig_path }}
      --namespace=test-ssh-bastion
      --output=jsonpath='{.status.loadBalancer.ingress[0].hostname}'
    register: oc_get
    until:
    - oc_get.stdout != ''
    changed_when: false

  - name: Set fact ssh_bastion
    set_fact:
      ssh_bastion: "{{ oc_get.stdout }}"

  - name: Create Ansible Inventory File
    template:
      src: hosts.j2
      dest: "{{ cluster_dir }}/ansible-hosts"
EOF

cat > create_machineset.yaml <<-'EOF'
---
- name: Create machineset_name
  set_fact:
    machineset_name: "{{ machineset_obj.metadata.name ~ '-' ~ platform_type }}"

- name: Update machineset definition
  set_fact:
    machineset: "{{ machineset_obj | combine(dict_edit, recursive=True) }}"
  vars:
    dict_edit:
      metadata:
        name: "{{ machineset_name }}"
        resourceVersion: ""
      spec:
        selector:
          matchLabels:
            machine.openshift.io/cluster-api-machineset: "{{ machineset_name }}"
        template:
          metadata:
            labels:
              machine.openshift.io/cluster-api-machineset: "{{ machineset_name }}"
          spec:
            providerSpec:
              value:
                ami:
                  id: "{{ aws_ami }}"
                keyName: "openshift-dev"

- name: Import machineset definition
  command: >
    oc apply -f -
    --kubeconfig={{ kubeconfig_path }}
  register: oc_apply
  args:
    stdin: "{{ machineset | to_yaml }}"
  until: oc_apply is succeeded
  changed_when:
  - ('created' in oc_apply.stdout) or
    ('configured' in oc_apply.stdout)

- name: Get machines in the machineset
  command: >
    oc get machine
    --kubeconfig={{ kubeconfig_path }}
    --namespace=openshift-machine-api
    --selector='machine.openshift.io/cluster-api-machineset={{ machineset_name }}'
    --output=json
  register: oc_get_machine
  until: oc_get_machine is succeeded
  changed_when: false

- name: Create list of machines
  set_fact:
    worker_machines: "{{ (oc_get_machine.stdout | from_json)['items'] | map(attribute='metadata.name') | list }}"

- name: Wait for machines to be provisioned
  command: >
    oc get machine {{ item }}
    --kubeconfig={{ kubeconfig_path }}
    --namespace=openshift-machine-api
    --output=json
  loop: "{{ worker_machines }}"
  register: new_machine
  until:
  - new_machine.stdout != ''
  - (new_machine.stdout | from_json).status is defined
  - (new_machine.stdout | from_json).status.phase == 'Provisioned'
  retries: 36
  delay: 5
  changed_when: false

- name: Get machines in the machineset after provisioning
  command: >
    oc get machine
    --kubeconfig={{ kubeconfig_path }}
    --namespace=openshift-machine-api
    --selector='machine.openshift.io/cluster-api-machineset={{ machineset_name }}'
    --output=json
  register: oc_get_machine
  until: oc_get_machine is succeeded
  changed_when: false

- name: Add hostname to new_workers_list
  set_fact:
    new_workers_list: "{{ new_workers_list + [ item.status.addresses | selectattr('type', 'match', '^InternalDNS$') | map(attribute='address') | first ] }}"
  loop: "{{ (oc_get_machine.stdout | from_json)['items'] }}"
EOF

cat > hosts.j2 <<-'EOF'
[all:vars]
openshift_kubeconfig_path={{ kubeconfig_path }}
openshift_pull_secret_path={{ pull_secret_path }}

[new_workers:vars]
ansible_ssh_common_args="-o IdentityFile={{ private_key_path }} -o StrictHostKeyChecking=no -o ProxyCommand=\"ssh -o IdentityFile={{ private_key_path }} -o ConnectTimeout=30 -o ConnectionAttempts=100 -o StrictHostKeyChecking=no -W %h:%p -q core@{{ ssh_bastion }}\""
ansible_user={{ platform_type_dict[platform_type].username }}
ansible_become=True

[new_workers]
# hostnames must be listed by what `hostname -f` returns on the host
# this is the name the cluster will use
{% for host in new_workers_list %}
{{ host }}
{% endfor %}

[workers:children]
new_workers
EOF

ansible-playbook create-machines.yaml -vvv

cp "${SHARED_DIR}/ansible-hosts" "${ARTIFACT_DIR}"
ansible-inventory -i "${SHARED_DIR}/ansible-hosts" --list --yaml > "${ARTIFACT_DIR}/ansible-parsed-inventory"
