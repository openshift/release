#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

echo "Restoring seed hub (kni-qe-108) flat inventory from seed- prefixed files"
for key in bastion hypervisor master0 all bastions hypervisors nodes masters; do
  cp "${SHARED_DIR}/seed-${key}" "${SHARED_DIR}/${key}"
  echo "  restored: ${key}"
done
