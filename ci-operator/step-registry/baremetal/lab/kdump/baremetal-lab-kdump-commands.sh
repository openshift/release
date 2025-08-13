#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

if [ "${ENABLE_KDUMP:-false}" != "true" ]; then
  echo "kernel dump is not enabled. Skipping..."
  exit 0
fi

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' TERM ERR

[ -z "${AUX_HOST}" ] && { echo "AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${architecture}" ] && { echo "\$architecture is not filled. Failing."; exit 1; }

workdir=`mktemp -d`

ocp_version=$(oc adm release info --registry-config ${CLUSTER_PROFILE_DIR}/pull-secret ${RELEASE_IMAGE_LATEST} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
echo "ocp_version: ${ocp_version}"

# generate array with current version + previous one, this is needed for non-GA releases where Butane doesn't support yet the latest version
butane_version_list=("${ocp_version}.0" "$(echo ${ocp_version} | awk -F. -v OFS=. '{$NF -= 1 ; print}').0")
echo "butane_version_list:" "${butane_version_list[@]}"

declare -a roles=("master" "worker")
ret_code=1

for butane_version in "${butane_version_list[@]}"; do
  echo "Trying Butane version: ${butane_version}"
  all_success=true

  for role in "${roles[@]}"; do
    bu_file="${workdir}/${role}_kdump.bu"
    yml_file="${workdir}/manifest_${role}_kdump.yml"

    cat > "$bu_file" << EOF
variant: openshift
version: ${butane_version}
metadata:
  name: 99-${role}-kdump
  labels:
    machineconfiguration.openshift.io/role: ${role}
openshift:
  kernel_arguments:
    - crashkernel=256M
storage:
  files:
    - path: /etc/kdump.conf
      mode: 0644
      overwrite: true
      contents:
        inline: |
          path /var/crash
          core_collector makedumpfile -l --message-level 7 -d 31

    - path: /etc/sysconfig/kdump
      mode: 0644
      overwrite: true
      contents:
        inline: |
          KDUMP_COMMANDLINE_REMOVE="hugepages hugepagesz slub_debug quiet log_buf_len swiotlb"
          KDUMP_COMMANDLINE_APPEND="irqpoll nr_cpus=1 reset_devices cgroup_disable=memory mce=off numa=off udev.children-max=2 panic=10 rootflags=nofail acpi_no_memhotplug transparent_hugepage=never nokaslr novmcoredd hest_disable"
          KEXEC_ARGS="-s"
          KDUMP_IMG="vmlinuz"

systemd:
  units:
    - name: kdump.service
      enabled: true
EOF

    if ! butane "$bu_file" > "$yml_file"; then
      echo "Butane failed for ${role} using version '${butane_version}' (non-GA?)."
      all_success=false
      break
    fi

    cp -f "$yml_file" "${SHARED_DIR}/manifest_${role}_tang_disk_encryption.yml"
  done

  if $all_success; then
    echo "Succeeded using Butane version '${butane_version}'"
    ret_code=0
    break
  fi
done

if [ $ret_code -ne 0 ]; then
  echo "Butane failed for all provided versions. Aborting."
  exit 1
fi
