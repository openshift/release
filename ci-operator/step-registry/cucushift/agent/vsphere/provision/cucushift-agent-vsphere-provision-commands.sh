#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM
# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "$(date -u --rfc-3339=seconds) - failed to acquire lease"
  exit 1
fi

export HOME=/tmp

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
declare target_hw_version
declare vsphere_datacenter
declare vsphere_datastore
declare vsphere_portgroup
source "${SHARED_DIR}/vsphere_context.sh"
source "${SHARED_DIR}/govc.sh"
unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

echo "Installing from initial release $OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"
oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" "$OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE" \
  --command=openshift-install --to=/tmp

echo "Creating agent image..."
dir=/tmp/installer
mkdir "${dir}/"
pushd ${dir}
cp -t "${dir}" "${SHARED_DIR}"/{install-config.yaml,agent-config.yaml}

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi

/tmp/openshift-install agent create image --dir="${dir}" --log-level debug &

if ! wait $!; then
  cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/.openshift_install.log"
  exit 1
fi
echo "Copying kubeconfig to the shared directory..."
cp -t "${SHARED_DIR}" \
  "${dir}/auth/kubeadmin-password" \
  "${dir}/auth/kubeconfig"

# Why do we want this silent? We want to see what curl is doing
# vsphere_context.sh now contains SSL_CERT_FILE that needs to be unset for curl
env -u SSL_CERT_FILE curl -L https://github.com/vmware/govmomi/releases/latest/download/govc_Linux_x86_64.tar.gz -o ${HOME}/glx.tar.gz

tar -C ${HOME} -xvf ${HOME}/glx.tar.gz govc && rm -f ${HOME}/glx.tar.gz

cluster_name=$(<"${SHARED_DIR}"/cluster-name.txt)
echo "agent.x86_64_${cluster_name}.iso" >"${SHARED_DIR}"/agent-iso.txt
agent_iso=$(<"${SHARED_DIR}"/agent-iso.txt)

echo "uploading ${agent_iso} to datastore ${vsphere_datastore}"

for ((i = 0; i < 3; i++)); do
  if env -u SSL_CERT_FILE -u GOVC_TLS_CA_CERTS /tmp/govc datastore.upload -ds "${vsphere_datastore}" agent.x86_64.iso agent-installer-isos/"${agent_iso}"; then
    echo "$(date -u --rfc-3339=seconds) - Agent ISO has been uploaded successfully!!"
    status=0
    break
  else
    echo "$(date -u --rfc-3339=seconds) - Failed to upload agent iso. Retrying..."
    status=1
    sleep 2
  fi
done
if [ "$status" -ne 0 ]; then
  echo "Agent ISO upload failed after 3 attempts!!!"
  exit 1
fi

# These two environment variables are coming from vsphere_context.sh
# and govc.sh. The file they are assigned to is not available in this step.
unset SSL_CERT_FILE 
unset GOVC_TLS_CA_CERTS

total_host="$((MASTERS + WORKERS))"
declare -a mac_addresses
mapfile -t mac_addresses <"${SHARED_DIR}"/mac-addresses.txt
declare -a hostnames
mapfile -t hostnames <"${SHARED_DIR}"/hostnames.txt

folder_name=$(<"${SHARED_DIR}"/cluster-name.txt)
/tmp/govc folder.create "/${vsphere_datacenter}/vm/${folder_name}"

[[ ${MASTERS} -eq 1 ]] && cpu="8" || cpu="4"

for ((i = 0; i < total_host; i++)); do
  vm_name=${hostnames[$i]}
  echo "creating Vm $vm_name.."
  /tmp/govc vm.create \
    -m=16384 \
    -g=coreos64Guest \
    -c=${cpu} \
    -disk=120GB \
    -net="${vsphere_portgroup}" \
    -firmware=efi \
    -on=false \
    -version vmx-"${target_hw_version}" \
    -folder="/${vsphere_datacenter}/vm/${folder_name}" \
    -iso-datastore="${vsphere_datastore}" \
    -iso=agent-installer-isos/"${agent_iso}" \
    "$vm_name"

  /tmp/govc vm.change \
    -e="disk.EnableUUID=1" \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"

  /tmp/govc vm.change \
    -nested-hv-enabled=true \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"

  /tmp/govc device.boot \
    -secure \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"

  /tmp/govc vm.network.change \
    -vm="/${vsphere_datacenter}/vm/${folder_name}/${vm_name}" \
    -net "${vsphere_portgroup}" \
    -net.address "${mac_addresses[$i]}" ethernet-0

  /tmp/govc vm.power \
    -on=true "/${vsphere_datacenter}/vm/${folder_name}/${vm_name}"
done

export KUBECONFIG=${SHARED_DIR}/kubeconfig
## Monitor for `bootstrap-complete`
echo "$(date -u --rfc-3339=seconds) - Monitoring for bootstrap to complete"
/tmp/openshift-install --dir="${dir}" agent wait-for bootstrap-complete &

if ! wait $!; then
  echo "ERROR: Bootstrap failed. Aborting execution."
  exit 1
fi

## Monitor for cluster completion
echo "$(date -u --rfc-3339=seconds) - Monitoring for cluster completion..."

# When using line-buffering there is a potential issue that the buffer is not filled (or no new line) and this waits forever
# or in our case until the four hour CI timer is up.
/tmp/openshift-install --dir="${dir}" agent wait-for install-complete 2>&1 | stdbuf -o0 grep -v password &

if ! wait "$!"; then
  echo "ERROR: Installation failed. Aborting execution."
  exit 1
fi

version=$(oc get clusterversion -o jsonpath={..desired.version} | cut -d '.' -f 1,2)
if [[ $(echo -e "4.15\n$version" | sort -V | tail -n 1) == "$version" ]]; then
  echo "Ensure that all the cluster operators remain stable and ready until OCPBUGS-18658 is fixed."
  oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=60m
fi