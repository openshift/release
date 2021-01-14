#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi
# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

third_octet=$(grep -oP 'ci-segment-\K[[:digit:]]+' <(echo "${LEASED_RESOURCE}"))

export HOME=/tmp
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}
# Ensure ignition assets are configured with the correct invoker to track CI jobs.
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}

echo "$(date -u --rfc-3339=seconds) - Creating reusable variable files..."
# Create basedomain.txt
echo "origin-ci-int-aws.dev.rhcloud.com" > "${SHARED_DIR}"/basedomain.txt
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)

# Create clustername.txt
echo "${NAMESPACE}-${JOB_NAME_HASH}" > "${SHARED_DIR}"/clustername.txt
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)

# Create clusterdomain.txt
echo "${cluster_name}.${base_domain}" > "${SHARED_DIR}"/clusterdomain.txt
cluster_domain=$(<"${SHARED_DIR}"/clusterdomain.txt)

ssh_pub_key_path="${CLUSTER_PROFILE_DIR}/ssh-publickey"
install_config="${SHARED_DIR}/install-config.yaml"
tfvars_path=/var/run/secrets/ci.openshift.io/cluster-profile/vmc.secret.auto.tfvars
vsphere_user=$(grep -oP 'vsphere_user\s*=\s*"\K[^"]+' ${tfvars_path})
vsphere_password=$(grep -oP 'vsphere_password\s*=\s*"\K[^"]+' ${tfvars_path})
ova_url="$(jq -r '.baseURI + .images["vmware"].path' /var/lib/openshift-install/rhcos.json)"
vm_template="${ova_url##*/}"


echo "$(date -u --rfc-3339=seconds) - Creating govc.sh file..."
cat >> "${SHARED_DIR}/govc.sh" << EOF
export GOVC_URL=vcenter.sddc-44-236-21-251.vmwarevmc.com
export GOVC_USERNAME="${vsphere_user}"
export GOVC_PASSWORD="${vsphere_password}"
export GOVC_INSECURE=1
export GOVC_DATACENTER=SDDC-Datacenter
export GOVC_DATASTORE=WorkloadDatastore
EOF

echo "$(date -u --rfc-3339=seconds) - Extend install-config.yaml ..."

cat >> "${install_config}" << EOF
baseDomain: $base_domain
controlPlane:
  name: "master"
  replicas: 3
compute:
- name: "worker"
  replicas: 0
platform:
  vsphere:
    cluster: Cluster-1
    datacenter: SDDC-Datacenter
    defaultDatastore: WorkloadDatastore
    network: "${LEASED_RESOURCE}"
    password: ${vsphere_password}
    username: ${vsphere_user}
    vCenter: vcenter.sddc-44-236-21-251.vmwarevmc.com
    folder: "/SDDC-Datacenter/vm/${cluster_name}"
EOF

echo "$(date -u --rfc-3339=seconds) - Create terraform.tfvars ..."
cat > "${SHARED_DIR}/terraform.tfvars" <<-EOF
machine_cidr = "192.168.${third_octet}.0/27"
vm_template = "${vm_template}"
vsphere_cluster = "Cluster-1"
vsphere_datacenter = "SDDC-Datacenter"
vsphere_datastore = "WorkloadDatastore"
vsphere_server = "vcenter.sddc-44-236-21-251.vmwarevmc.com"
ipam = "ipam.vmc.ci.openshift.org"
cluster_id = "${cluster_name}"
base_domain = "${base_domain}"
cluster_domain = "${cluster_domain}"
ssh_public_key_path = "${ssh_pub_key_path}"
compute_memory = "16384"
compute_num_cpus = "4"
vm_network = "${LEASED_RESOURCE}"
vm_dns_addresses = ["10.0.0.2"]
bootstrap_ip_address = "192.168.${third_octet}.3"
lb_ip_address = "192.168.${third_octet}.2"
compute_ip_addresses = ["192.168.${third_octet}.7","192.168.${third_octet}.8","192.168.${third_octet}.9"]
control_plane_ip_addresses = ["192.168.${third_octet}.4","192.168.${third_octet}.5","192.168.${third_octet}.6"]
EOF

dir=/tmp/installer
mkdir "${dir}/"
pushd ${dir}
cp -t "${dir}" \
    "${SHARED_DIR}/install-config.yaml"

### Create manifests
echo "Creating manifests..."
openshift-install --dir="${dir}" create manifests &

set +e
wait "$!"
ret="$?"
set -e

if [ $ret -ne 0 ]; then
  cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/.openshift_install.log"
  exit "$ret"
fi

### Remove control plane machines
echo "Removing control plane machines..."
rm -f openshift/99_openshift-cluster-api_master-machines-*.yaml

### Remove compute machinesets (optional)
echo "Removing compute machinesets..."
rm -f openshift/99_openshift-cluster-api_worker-machineset-*.yaml

### Make control-plane nodes unschedulable
echo "Making control-plane nodes unschedulable..."
sed -i "s;mastersSchedulable: true;mastersSchedulable: false;g" manifests/cluster-scheduler-02-config.yml

### Create Ignition configs
echo "Creating Ignition configs..."
openshift-install --dir="${dir}" create ignition-configs &

set +e
wait "$!"
ret="$?"
set -e

cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/.openshift_install.log"

if [ $ret -ne 0 ]; then
  exit "$ret"
fi

cp -t "${SHARED_DIR}" \
    "${dir}/auth/kubeadmin-password" \
    "${dir}/auth/kubeconfig" \
    "${dir}/metadata.json" \
    "${dir}"/*.ign

# Removed tar of openshift state. Not enough room in SHARED_DIR with terraform state

popd
