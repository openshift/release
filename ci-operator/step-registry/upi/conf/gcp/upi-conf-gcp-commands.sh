#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export HOME=/tmp

if [[ -z "$RELEASE_IMAGE_LATEST" ]]; then
  echo "RELEASE_IMAGE_LATEST is an empty string, exiting"
  exit 1
fi
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${RELEASE_IMAGE_LATEST}"

# Ensure ignition assets are configured with the correct invoker to track CI jobs.
export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}"

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"

dir=/tmp/installer
mkdir "${dir}"
pushd "${dir}"
cp -t "${dir}" \
    "${SHARED_DIR}/install-config.yaml"

### Read XPN config, if exists
if [[ -s "${SHARED_DIR}/xpn.json" ]]; then
  echo "Reading variables from ${SHARED_DIR}/xpn.json..."
  IS_XPN=1
  HOST_PROJECT="$(jq -r '.hostProject' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_NETWORK="$(jq -r '.clusterNetwork' "${SHARED_DIR}/xpn.json")"
  HOST_PROJECT_COMPUTE_SUBNET="$(jq -r '.computeSubnet' "${SHARED_DIR}/xpn.json")"

  HOST_PROJECT_NETWORK_NAME="$(basename "${HOST_PROJECT_NETWORK}")"
  HOST_PROJECT_COMPUTE_SUBNET_NAME="$(basename "${HOST_PROJECT_COMPUTE_SUBNET}")"
fi

if ! pip -V; then
    echo "pip is not installed: installing"
    if python -c "import sys; assert(sys.version_info >= (3,0))"; then
      python -m ensurepip --user || easy_install --user 'pip'
    else
      echo "python < 3, installing pip<21"
      python -m ensurepip --user || easy_install --user 'pip<21'
    fi
fi
export PATH="${HOME}/.local/bin:${PATH}"

echo "Installing python modules: yaml"
python -c "import yaml" || pip install --user pyyaml

### Empty the compute pool (optional)
echo "Emptying the compute pool..."
python -c '
import yaml;
path = "install-config.yaml";
data = yaml.load(open(path));
data["compute"] = [ { "name": "worker", "replicas": 0 } ];
open(path, "w").write(yaml.dump(data, default_flow_style=False))'

### Enable private cluster setting (optional)
if [[ -v IS_XPN ]]; then
  echo "Enabling private cluster setting..."
  python -c '
import yaml;
path = "install-config.yaml";
data = yaml.load(open(path));
data["publish"] = "Internal";
open(path, "w").write(yaml.dump(data, default_flow_style=False))'
fi

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_START"

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
python -c '
import yaml;
path = "manifests/cluster-scheduler-02-config.yml";
data = yaml.load(open(path));
data["spec"]["mastersSchedulable"] = False;
open(path, "w").write(yaml.dump(data, default_flow_style=False))'

### Remove DNS Zones (optional)
if [[ -v IS_XPN ]]; then
  echo "Removing DNS Zones..."
  python -c '
import yaml;
path = "manifests/cluster-dns-02-config.yml";
data = yaml.load(open(path));
del data["spec"]["privateZone"];
open(path, "w").write(yaml.dump(data, default_flow_style=False))'
fi

### Update the cloud-provider manifest ([Shared VPC (XPN)][sharedvpc] only)
if [[ -v IS_XPN ]]; then
  echo "Updating the cloud-provider manifest..."
  sed -i "s/    subnetwork-name.*/    network-project-id = ${HOST_PROJECT}\\n    network-name    = ${HOST_PROJECT_NETWORK_NAME}\\n    subnetwork-name = ${HOST_PROJECT_COMPUTE_SUBNET_NAME}/" manifests/cloud-provider-config.yaml
fi

### Enable external ingress (optional)
if [[ -v IS_XPN ]]; then
  echo "Removing publish:internal bits..."
  python -c '
import yaml;
path = "manifests/cluster-ingress-default-ingresscontroller.yaml";
data = yaml.load(open(path));
data["spec"]["endpointPublishingStrategy"]["loadBalancer"]["scope"] = "External";
open(path, "w").write(yaml.dump(data, default_flow_style=False))'
fi

### Create Ignition configs
echo "Creating Ignition configs..."
openshift-install --dir="${dir}" create ignition-configs &

set +e
wait "$!"
ret="$?"
set -e

echo "$(date +%s)" > "${SHARED_DIR}/TEST_TIME_INSTALL_END"

cp "${dir}/.openshift_install.log" "${ARTIFACT_DIR}/.openshift_install.log"

if [ $ret -ne 0 ]; then
  exit "$ret"
fi

cp -t "${SHARED_DIR}" \
    "${dir}/auth/kubeadmin-password" \
    "${dir}/auth/kubeconfig" \
    "${dir}/metadata.json" \
    ${dir}/*.ign

tar -czf "${SHARED_DIR}/.openshift_install_state.json.tgz" ".openshift_install_state.json"

popd
