#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

CLUSTER=$(govc find "/${GOVC_DATACENTER}" -type c | head -n 1)
AVGMHZ=$(govc host.info -json "${CLUSTER}" | jq -r '[.hostSystems[].summary.hardware.cpuMhz] | add / length')


echo "$(date -u --rfc-3339=seconds) - ${CLUSTER} has an average physical cpu speed of ${AVGMHZ}"


# TODO: ***** temp values
#
#
NUMOFVMS=6
NUMOFCPUS=4
MEMORY=16384

CPURES=$((AVGMHZ * NUMOFCPUS * NUMOFVMS))
MEMRES=$((MEMORY * NUMOFVMS))

# TODO: ****** NAMESPACE might not be unique enough in the scenario when multiple jobs run in the same namespace

# Periodic jobs have higher priority and have 100 % of their resources reserved.
if [[ ${JOB_TYPE} == "periodic" ]]; then
    govc pool.create -cpu.reservation=$CPURES -cpu.shares=high -mem.shares=high -mem.reservation=$MEMRES "${GOVC_RESOURCE_POOL}/${NAMESPACE}"
else

# All other jobs have 50% reservations and normal shares.
    CPURES=$((CPURES/2))
    MEMRES=$((MEMRES/2))
    govc pool.create -cpu.reservation=$CPURES -cpu.shares=normal -mem.shares=normal -mem.reservation=$MEMRES "${GOVC_RESOURCE_POOL}/${NAMESPACE}"
fi
