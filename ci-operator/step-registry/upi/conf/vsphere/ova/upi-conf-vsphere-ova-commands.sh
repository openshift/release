#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

HOME=/tmp
export HOME

echo "$(date -u --rfc-3339=seconds) - Locating RHCOS image for release..."

ova_url=$(<"${SHARED_DIR}"/ova_url.txt)
vm_template="${ova_url##*/}"

# Troubleshooting UPI OVA import issue
echo "$(date -u --rfc-3339=seconds) - vm_template: ${vm_template}"

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
   "Name": "${vm_template}",
   "NetworkMapping":[{"Name":"VM Network","Network":"${LEASED_RESOURCE}"}]
}
EOF

echo "$(date -u --rfc-3339=seconds) - Checking if RHCOS OVA needs to be downloaded from ${ova_url}..."

if [[ "$(govc vm.info "${vm_template}" | wc -c)" -eq 0 ]]
then
    echo "$(date -u --rfc-3339=seconds) - Creating a template for the VMs from ${ova_url}..."
    curl -L -o /tmp/rhcos.ova "${ova_url}"
    govc import.ova -options=/tmp/rhcos.json /tmp/rhcos.ova &
    wait "$!"
fi

hw_versions=(15 17 19)
for hw_version in "${hw_versions[@]}"; do
    if [[ "$(govc vm.info "${vm_template}-hw${hw_version}" | wc -c)" -eq 0 ]]
    then
        echo "$(date -u --rfc-3339=seconds) - Cloning and upgrading ${vm_template} to hw version ${hw_version}..."
        govc vm.clone -on=false -vm="${vm_template}" "${vm_template}-hw${hw_version}"
        govc vm.upgrade -vm="${vm_template}-hw${hw_version}" -version=${hw_version}
    fi
done
