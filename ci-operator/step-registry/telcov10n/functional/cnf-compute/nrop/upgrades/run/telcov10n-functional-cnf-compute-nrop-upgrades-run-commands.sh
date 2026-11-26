#!/bin/bash
set -euo pipefail
umask 077

export CLUSTER_NAME

inventory=/eco-ci-cd/inventories/ocp-deployment
for kind in host_vars group_vars; do
    mkdir -p "${inventory}/${kind}"
    for file in "${SHARED_DIR}/${kind}_"*; do
        [[ -f "${file}" ]] || continue
        name=${file##*/}
        cp -- "${file}" "${inventory}/${kind}/${name#"${kind}"_}"
    done
done

export NROP_ARTIFACTS="/tmp/nrop-upgrades-${BUILD_ID}/artifacts"
export NROP_WORKDIR="/tmp/nrop-upgrades-${BUILD_ID}/work"
vars_file=$(mktemp)
collect_playbook=$(mktemp)

python3 - "${vars_file}" <<'PY'
import json
import os
import sys

values = {
    "kubeconfig": "/home/telcov10n/project/generated/" + os.environ["CLUSTER_NAME"] + "/auth/kubeconfig",
    "artifacts_folder": os.environ["NROP_ARTIFACTS"],
    "tmp_workdir": os.environ["NROP_WORKDIR"],
    "upgrade_type": os.environ["UPGRADE_TYPE"],
    "from_ocp_version": os.environ["VERSION"],
    "to_ocp_version": os.environ["TO_OCP_VERSION"],
    "upgrade_env": os.environ["UPGRADE_ENV"],
    "nrop_channel": os.environ["NROP_CHANNEL"],
    "custom_ocp_images": os.environ["CUSTOM_OCP_IMAGES"],
    "apply_perf_profile": os.environ["APPLY_PERF_PROFILE"].lower() == "true",
    "verify_deployment": os.environ["VERIFY_DEPLOYMENT"].lower() == "true",
    "canary_node_count": os.environ["CANARY_NODE_COUNT"],
    "canary_cleanup": os.environ["CANARY_CLEANUP"].lower() == "true",
}
if values["upgrade_type"] in ("eus", "canary"):
    persistent_workload = os.environ["VERIFY_PERSISTENT_WORKLOAD"].strip().lower()
    if persistent_workload not in ("true", "false"):
        raise SystemExit("VERIFY_PERSISTENT_WORKLOAD must be true or false")
    values["verify_persistent_workload"] = persistent_workload == "true"
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump(values, output)
PY

cat > "${collect_playbook}" <<'YAML'
---
- hosts: bastion
  gather_facts: false
  tasks:
    - name: Find NROP upgrade result files
      ansible.builtin.find:
        paths: "{{ artifacts_folder }}"
        patterns:
          - ocp-upgrades.yaml
          - nrop-upgrades-lane-*.json
          - ocp-upgrade-hop-*.json
          - nrop-image-digests-*.yaml
          - nrop-cr-setup.yaml
          - nrop-cr-migrate.yaml
          - nrop-cr-cleanup-selinux.yaml
          - nrop-cr-final.yaml
          - nrop-cr-eus-selinux.json
          - canary-final-worker-profile.json
          - canary-final-worker-kubelet.json
          - smoke-persistent-pod-*.json
          - smoke-persistent-pod-*.txt
          - smoke-reboot-history.json
          - smoke-reboot-history.txt
      register: nrop_result_files

    - name: Collect NROP upgrade result files
      ansible.builtin.fetch:
        src: "{{ item.path }}"
        dest: "{{ lookup('env', 'ARTIFACT_DIR') }}/"
        flat: true
      loop: "{{ nrop_result_files.files }}"
      loop_control:
        label: "{{ item.path | basename }}"

    - name: Find NROP manifest directories
      ansible.builtin.find:
        paths: "{{ artifacts_folder }}"
        patterns: manifests-*
        file_type: directory
      register: nrop_manifest_directories

    - name: Find exported NROP manifests
      ansible.builtin.find:
        paths: "{{ nrop_manifest_directories.files | map(attribute='path') | list }}"
        patterns: '*.yaml'
        file_type: file
      register: nrop_manifest_files
      when: nrop_manifest_directories.matched | int > 0

    - name: Collect exported NROP manifests
      ansible.builtin.fetch:
        src: "{{ item.path }}"
        dest: "{{ lookup('env', 'ARTIFACT_DIR') }}/{{ item.path | dirname | basename }}/{{ item.path | basename }}"
        flat: true
      loop: "{{ nrop_manifest_files.files | default([]) }}"
      loop_control:
        label: "{{ item.path | dirname | basename }}/{{ item.path | basename }}"
YAML

cd /eco-ci-cd
# Collect artifacts even if the upgrade fails, then return the upgrade's status.
status=0
ansible-playbook playbooks/compute/nrop-upgrades.yml \
    -i "${inventory}/build-inventory.py" --extra-vars "@${vars_file}" || status=$?

if ! ansible-playbook "${collect_playbook}" \
    -i "${inventory}/build-inventory.py" --extra-vars "@${vars_file}"; then
    echo "Warning: could not collect all NROP upgrade result files." >&2
fi
rm -f -- "${vars_file}" "${collect_playbook}"
exit "${status}"
