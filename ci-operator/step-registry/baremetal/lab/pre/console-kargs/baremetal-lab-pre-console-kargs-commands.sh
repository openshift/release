#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

function join_by_semicolon() {
  local array_string="${1}"
  local prefix="${2}"
  local postfix="${3}"
  while [[ "${array_string}" = *\;* ]]; do
    # print initial part of string; then, remove it
    echo -n "${prefix}${array_string%%;*}${postfix} "
    array_string="${array_string#*;}"
  done
  # either the last or only one element is printed at the end
  if [ "${#array_string}" -gt 0 ]; then
    echo -n "${prefix}${array_string}${postfix} "
  fi
}

echo "Rendering the ignition hook from butane..."

base_url="http://${INTERNAL_NET_IP}/$(<"${SHARED_DIR}/cluster_name")"

# We use a different console-hook ignition file for each node to allow the configuration of heterogeneous nodes
# (i.e., nodes from different vendors)
# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  if [ "${#mac}" -eq 0 ] || [ "${#name}" -eq 0 ]; then
    echo "Error while unmarshalling hosts entries"
    exit 1
  fi
  mac_prefix=${mac//:/-}
  role=${name%%-[0-9]*}
  role=${role%%-a*}
  echo "Rendering ignition for ${name} (${role}) - #${host}..."
  butane --strict --raw -o "${SHARED_DIR}/${mac_prefix}-console-hook.ign" <<EOF
variant: fcos
version: 1.3.0
systemd:
  units:
  - name: console-hook.service
    enabled: true
    contents: |
      [Unit]
      Description=Run installer with custom kargs
      Requires=coreos-installer-pre.target
      After=coreos-installer-pre.target
      OnFailure=emergency.target
      OnFailureJobMode=replace-irreversibly
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=oneshot
      ExecStart=/usr/bin/coreos-installer install $root_device \
        --delete-karg console=ttyS0,115200n8 $(join_by_semicolon "${console_kargs}" "--append-karg console=" "") \
        --ignition-url ${base_url%%*(/)}/${role}.ign \
        --insecure-ignition --copy-network
      # Some servers' firmware push any new detected boot options to the tail of the boot order.
      # When other boot options are present and bootable, such a server will boot from them instead of the new one.
      # As a (temporary?) workaround, we manually add the boot option.
      # NOTE: it's assumed that old OSes boot options are removed from the boot options list during the wipe operations.
      # xrefs: https://bugzilla.redhat.com/show_bug.cgi?id=1997805
      #        https://github.com/coreos/fedora-coreos-tracker/issues/946
      #        https://github.com/coreos/fedora-coreos-tracker/issues/947
      ExecStart=/usr/bin/bash -c ' \
        ARCH=\$(uname -m | sed "s/x86_64/x64/;s/aarch64/aa64/"); \
        /usr/sbin/efibootmgr -c -d "$root_device" -p 2 -c -L "Red Hat CoreOS" -l "\\\\EFI\\\\redhat\\\\shim\$ARCH.efi" \
      '
      ExecStart=/usr/bin/systemctl --no-block reboot
      StandardOutput=kmsg+console
      StandardError=kmsg+console

      [Install]
      RequiredBy=default.target

EOF
done

echo "Ignition files are ready to deploy."
