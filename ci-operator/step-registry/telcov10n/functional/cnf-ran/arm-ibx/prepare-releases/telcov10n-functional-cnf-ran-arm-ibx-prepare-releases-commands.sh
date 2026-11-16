#!/bin/bash
set -euo pipefail

if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
  exit 0
fi
: "${CLUSTER_NAME:?CLUSTER_NAME must be configured}"
: "${SEED_SPOKE_CLUSTER:?SEED_SPOKE_CLUSTER must be configured}"
if [[ ! -s "${SHARED_DIR}/arm-ibx-seed-image" ]]; then
  echo "Successful seed generation is required before target preparation" >&2
  exit 1
fi
case "${VERSION}" in
  4.20|4.22|5.0) ;;
  *) echo "Supported ARM IBX lanes are 4.20, 4.22, and 5.0" >&2; exit 1 ;;
esac
if [[ "${SPOKE_ARCH}" != "multi" ]]; then
  echo "ARM IBX requires SPOKE_ARCH=multi" >&2
  exit 1
fi

cd /eco-ci-cd
mkdir -p inventories/ocp-deployment/{group_vars,host_vars}
for inventory in all bastions hypervisors nodes masters; do
  cp "${SHARED_DIR}/${inventory}" "inventories/ocp-deployment/group_vars/${inventory}"
done
for inventory in bastion hypervisor; do
  cp "${SHARED_DIR}/${inventory}" "inventories/ocp-deployment/host_vars/${inventory}"
done

ansible-playbook playbooks/ran/arm-ibx-prepare-releases.yml \
  -i inventories/ocp-deployment/build-inventory.py \
  -e "arm_ibx_version=${VERSION} spoke_cluster=${SEED_SPOKE_CLUSTER} arm_ibx_releases_file=${SHARED_DIR}/arm-ibx-releases.json"
cp "${SHARED_DIR}/arm-ibx-releases.json" "${ARTIFACT_DIR}/arm-ibx-releases.json"
