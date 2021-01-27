#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

HOME=/tmp
export HOME

echo "$(date -u --rfc-3339=seconds) - Locating RHCOS image for release..."

openshift_install_path="/var/lib/openshift-install"
image_json_file="${openshift_install_path}/rhcos.json"
fcos_json_file="${openshift_install_path}/fcos.json"

if [[ -f "$fcos_json_file" ]]; then
    image_json_file=$fcos_json_file
fi

ova_url="$(jq -r '.baseURI + .images["vmware"].path' $image_json_file)"
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

# Troubleshooting UPI OVA import issue
govc vm.info "${vm_template}" || true

if [[ "$(govc vm.info "${vm_template}" | wc -c)" -eq 0 ]]
then
    echo "$(date -u --rfc-3339=seconds) - Creating a template for the VMs from ${ova_url}..."
    curl -L -o /tmp/rhcos.ova "${ova_url}"
    govc import.ova -options=/tmp/rhcos.json /tmp/rhcos.ova &
    wait "$!"
fi
