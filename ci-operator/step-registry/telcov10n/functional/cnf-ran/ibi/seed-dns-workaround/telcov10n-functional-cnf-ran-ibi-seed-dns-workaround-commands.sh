#!/bin/bash
# Temporary TLV DNS workaround; remove when the final lab hosts are in use.
set +x
set -euo pipefail
umask 077

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

prepare_inventory() {
  mkdir -p "${INVENTORY_PATH}/group_vars" "${INVENTORY_PATH}/host_vars"
  for key in all bastions; do
    cp "${SHARED_DIR}/seed-${key}" "${INVENTORY_PATH}/group_vars/${key}"
  done
  cp "${SHARED_DIR}/seed-bastion" "${INVENTORY_PATH}/host_vars/bastion"
  install -m 600 /var/group_variables/common/all/ansible_ssh_private_key \
    "${WORK_DIR}/ssh-key"
}

write_workaround() {
  cat > "${WORK_DIR}/apply-dns.sh" <<'SCRIPT'
#!/bin/sh
set -eu

cat > /etc/dnsmasq.d/custom-records.conf <<'EOF'
address=/disconnected.registry.local/10.6.184.110
address=/disconnected.registry.local/2620:52:9:16b8:6e00::110

host-record=api.kni-qe-127.telcov10n.eng.rdu2.dc.redhat.com,10.6.184.111,2620:52:9:16b8:6e00::111
host-record=api-int.kni-qe-127.telcov10n.eng.rdu2.dc.redhat.com,10.6.184.111,2620:52:9:16b8:6e00::111
address=/apps.kni-qe-127.telcov10n.eng.rdu2.dc.redhat.com/10.6.184.111
address=/apps.kni-qe-127.telcov10n.eng.rdu2.dc.redhat.com/2620:52:9:16b8:6e00::111

host-record=api.ibi-seed.lab.eng.tlv2.redhat.com,10.46.55.168
host-record=api-int.ibi-seed.lab.eng.tlv2.redhat.com,10.46.55.168
address=/apps.ibi-seed.lab.eng.tlv2.redhat.com/10.46.55.168
EOF

dnsmasq --test
systemctl restart dnsmasq
SCRIPT
}

main() {
  if [[ -f "${SHARED_DIR}/skip.txt" ||
        "${IBI_DNS_WORKAROUND_ENABLED:-false}" != "true" ]]; then
    echo "Skipping temporary seed DNS workaround."
    return 0
  fi
  if [[ "${CLUSTER_NAME}" != "kni-qe-127" ]]; then
    echo "Temporary seed DNS records are only valid for kni-qe-127." >&2
    return 1
  fi

  WORK_DIR=$(mktemp -d /tmp/ibi-seed-dns.XXXXXX)
  trap 'rm -rf -- "${WORK_DIR}"' EXIT
  prepare_inventory
  write_workaround

  cd /eco-ci-cd
  echo "Applying temporary seed DNS records and restarting dnsmasq."
  ansible bastion \
    -i "${INVENTORY_PATH}/build-inventory.py" \
    --extra-vars "ansible_private_key_file=${WORK_DIR}/ssh-key ansible_ssh_private_key_file=${WORK_DIR}/ssh-key" \
    --extra-vars '{"ansible_become": true}' \
    -m ansible.builtin.script \
    -a "${WORK_DIR}/apply-dns.sh"
}

main "$@"
