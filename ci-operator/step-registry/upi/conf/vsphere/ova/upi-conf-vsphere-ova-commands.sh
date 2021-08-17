#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

HOME=/tmp
export HOME

cluster_name=$(<"${SHARED_DIR}"/clustername.txt)
ova_url=$(<"${SHARED_DIR}"/ovaurl.txt)

echo "$(date -u --rfc-3339=seconds) - Configuring govc exports..."
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

cat > /tmp/rhcos.json << EOF
{
   "DiskProvisioning": "thin",
   "MarkAsTemplate": false,
   "PowerOn": false,
   "InjectOvfEnv": false,
   "WaitForIP": false,
   "Name": "${cluster_name}",
   "NetworkMapping":[{"Name":"VM Network","Network":"${LEASED_RESOURCE}"}]
}
EOF

# Hardware versions supported by ESXi
# 6.7U2 - 7.0U2
# https://kb.vmware.com/s/article/1003746
# https://docs.vmware.com/en/VMware-Cloud-on-AWS/services/com.vmware.vmc-aws-operations/GUID-52CED8FB-2E3A-4766-8C59-2EAD8E2C1D31.html
hardware_versions=("13" "15" "17")

echo "$(date -u --rfc-3339=seconds) - Creating a template for the VMs from ${ova_url}..."
curl -L -o /tmp/rhcos.ova "${ova_url}"
govc import.ova -options=/tmp/rhcos.json /tmp/rhcos.ova &
wait "$!"

set -x
version=${hardware_versions[$((RANDOM % 3))]}
govc vm.upgrade -version="${version}" -vm "${cluster_name}"
set +x
