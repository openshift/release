#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ! -n $(echo "$JOB_NAME" | grep -P '\-master\-') ]]; then
exit 0
fi

if [ "$(id -u)" -ge 500 ]; then
    echo "runner:x:$(id -u):$(id -g):,,,:/runner:/bin/bash" > /tmp/passwd
    cat /tmp/passwd >> /etc/passwd
    rm /tmp/passwd
fi

mkdir -p ~/.ssh/
chmod 700 ~/.ssh/

cat <<__EOF__ >~/.ansible.cfg
[defaults]
host_key_checking = False
__EOF__

cat <<__EOF__ >>~/.ssh/config
Host *
StrictHostKeyChecking no
__EOF__
chmod 400 ~/.ssh/config

set -o allexport

# shellcheck source=/dev/null
source "${CLUSTER_PROFILE_DIR}/ovirt.conf"


# Generate Ansible yaml files
cat > delete_disk_if_older.yaml	 <<-EOF
- name: "removing disk - {{ disk_id }} - {{ create_time }} "
  ovirt_disk:
    auth: "{{ ovirt_auth }}"
    state: absent
    name: "{{ disk_id }}"
  ignore_errors: yes
EOF

cat > delete_vm_if_older.yaml <<-EOF
- set_fact:
    seconds_since_creation: "{{(((engine_time|int)) - ( vm_creation_epoch | int ))/1000 }}"
- set_fact: to_be_deleted="{{  seconds_since_creation | int  >= seconds_limit | int }}"
- debug: msg="{{ 'seconds_since_creation:' + seconds_since_creation +' id:' + vm_id + ' name:' + vm_name +' vm_creation_epoch:' + vm_creation_epoch + ' to_be_deleted:' + ( to_be_deleted | string ) }}"
- name: "removing VM - {{ vm_name }} "
  ovirt_vm:
    auth: "{{ ovirt_auth }}"
    state: absent
    name: "{{ vm_name }}"
  ignore_errors: yes
  when: to_be_deleted
EOF

cat > delete_template_if_older.yaml	 <<-EOF
- set_fact:
    seconds_since_creation: "{{(((engine_time|int)) - ( template_creation_epoch | int ))/1000 }}"
- set_fact: to_be_deleted="{{  seconds_since_creation | int  >= seconds_limit | int }}"
- debug: msg="{{ 'seconds_since_creation:' + seconds_since_creation +' id:' + template_id + ' name:' + template_name +' template_creation_epoch:' + template_creation_epoch + ' to_be_deleted:' + ( to_be_deleted | string ) }}"
- name: "removing template - {{ template_name }} "
  ovirt_template:
    auth: "{{ ovirt_auth }}"
    state: absent
    name: "{{ template_name }}"
  ignore_errors: yes
  when: to_be_deleted
EOF

cat > ovirt_remove_old_resources.yaml <<-EOF
---
  - name: remove old resources from the oVirt CI engine
    hosts: localhost
    connection: local
    vars:
      max_hours: 5
      vms_to_exclude:
        - proxy-vm
      templates_to_exclude:
        - Blank
        - centos-7
    pre_tasks:
      - name: download CA file from engine
        get_url:
          url: "https://{{ lookup('env','OVIRT_ENGINE_URL') | urlsplit('hostname') }}/ovirt-engine/services/pki-resource?resource=ca-certificate&format=X509-PEM-CA"
          dest: "/tmp/ca.pem"
          validate_certs: no
      - name: Login to RHV
        no_log: true
        ovirt_auth:
          url: "{{ lookup('env','OVIRT_ENGINE_URL') }}"
          username: "{{ lookup('env','OVIRT_ENGINE_USERNAME') }}"
          password: "{{ lookup('env','OVIRT_ENGINE_PASSWORD') }}"
          ca_file: "/tmp/ca.pem"
          insecure: "true"
        tags:
          - always
    tasks:
      - name: collect engine general info
        uri:
          url: "{{ lookup('env','OVIRT_ENGINE_URL') }}"
          method: GET
          user: "{{ lookup('env','OVIRT_ENGINE_USERNAME') }}"
          password: "{{ lookup('env','OVIRT_ENGINE_PASSWORD') }}"
          body_format: json
          status_code: 200
          validate_certs: no
          headers:
            Content-Type: "application/json"
            Accept: "application/json"
        register: token_json

      - name: collect VM information using engine API
        uri:
          url: "{{ lookup('env','OVIRT_ENGINE_URL') }}/vms"
          method: GET
          user: "{{ lookup('env','OVIRT_ENGINE_USERNAME') }}"
          password: "{{ lookup('env','OVIRT_ENGINE_PASSWORD') }}"
          body_format: json
          status_code: 200
          validate_certs: no
          headers:
            Content-Type: "application/json"
            Accept: "application/json"
        register: vms_json

      - name: delete old vms
        no_log: true
        include_tasks: delete_vm_if_older.yaml
        vars:
          vm_creation_epoch: "{{ item['creation_time'] | int }}"
          engine_time: "{{token_json.json.time | int}}"
          seconds_limit: "{{ max_hours*3600  }}"
          vm_id: "{{ item['id'] }}"
          vm_name: "{{ item['name'] }}"
        loop: "{{ vms_json.json.vm }}"
        when: "item['name'] not in vms_to_exclude"

      - name: collect templates information using engine API
        uri:
          url: "{{ lookup('env','OVIRT_ENGINE_URL') }}/templates"
          method: GET
          user: "{{ lookup('env','OVIRT_ENGINE_USERNAME') }}"
          password: "{{ lookup('env','OVIRT_ENGINE_PASSWORD') }}"
          body_format: json
          status_code: 200
          validate_certs: no
          headers:
            Content-Type: "application/json"
            Accept: "application/json"
        register: templates_json

      - name: delete old templates
        include_tasks: delete_template_if_older.yaml
        no_log: true
        vars:
          template_creation_epoch: "{{ item['creation_time'] | int }}"
          engine_time: "{{token_json.json.time | int}}"
          seconds_limit: "{{ max_hours*3600  }}"
          template_id: "{{ item['id'] }}"
          template_name: "{{ item['name'] }}"
        loop: "{{ templates_json.json.template }}"
        when: "item['name'] not in templates_to_exclude"

    post_tasks:
      - name: Logout from RHV
        ovirt_auth:
          state: absent
          ovirt_auth: "{{ ovirt_auth }}"
EOF


cat > remove_yesterday_disks.yaml <<-EOF
---
  - name: remove old resources from the oVirt CI engine
    hosts: localhost
    connection: local
    vars:
      max_hours: 3
    tasks:
      - name: download CA file from engine
        get_url:
          url: "https://{{ lookup('env','OVIRT_ENGINE_URL') | urlsplit('hostname') }}/ovirt-engine/services/pki-resource?resource=ca-certificate&format=X509-PEM-CA"
          dest: "/tmp/ca.pem"
          validate_certs: no
        no_log: true
      - name: Login to RHV
        ovirt_auth:
          url: "{{ lookup('env','OVIRT_ENGINE_URL') }}"
          username: "{{ lookup('env','OVIRT_ENGINE_USERNAME') }}"
          password: "{{ lookup('env','OVIRT_ENGINE_PASSWORD') }}"
          ca_file: "/tmp/ca.pem"
          insecure: "true"
        tags:
          - always
      - name: find all PVC disk events
        ovirt_event_info:
          search: 'message="The disk*pvc*" and time=yesterday'
          auth: "{{ ovirt_auth }}"
        register: result
      - debug: msg="found Number of PVC events {{ result['ovirt_events'] | length }}"
      - name: delete disk if its exists
        include_tasks: delete_disk_if_older.yaml
        no_log: true
        vars:
          disk_id: "{{ (item['description'] | regex_search('The disk (.+) was', '\\\1') | first )[1:-1]}}"
          create_time: "{{ item['time'] }}"
        loop: "{{ result['ovirt_events'] }}"
        when:
            - "item['code']==2021"

      - name: find all ovirt disk events
        ovirt_event_info:
          search: 'message="The disk*ovirt*" and time=yesterday'
          auth: "{{ ovirt_auth }}"
        register: result
      - debug: msg="found Number of ovirt Disk events {{ result['ovirt_events'] | length }}"
      - name: delete disk if its exists
        include_tasks: delete_disk_if_older.yaml
        no_log: true
        vars:
          disk_id: "{{ (item['description'] | regex_search('The disk (.+) was', '\\\1') | first )[1:-1]}}"
          create_time: "{{ item['time'] }}"
        loop: "{{ result['ovirt_events'] }}"
        when:
            - "item['code']==2021"

      - name: Logout from RHV
        ovirt_auth:
          state: absent
          ovirt_auth: "{{ ovirt_auth }}"
        tags:
          - always
EOF

echo "######### running playbook `ansible-playbook ovirt_remove_old_resources.yaml` - removing leftover VMs  \n"
ansible-playbook ovirt_remove_old_resources.yaml

echo "######### running playbook `ansible-playbook remove_yesterday_disks.yaml` - removing leftover Disks - VMs and PVCs  \n"
ansible-playbook remove_yesterday_disks.yaml
