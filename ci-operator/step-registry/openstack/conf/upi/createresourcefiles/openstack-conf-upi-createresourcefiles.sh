#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

ASSETS_DIR=/tmp/assets_dir
rm -rf "${ASSETS_DIR}"
mkdir -p "${ASSETS_DIR}/"
cp "${SHARED_DIR}/install-config.yaml" "${ASSETS_DIR}/"

# Create Manifest files
echo "Creating manifest files"
TF_LOG=debug openshift-install --dir=${ASSETS_DIR} create manifests  --log-level=debug 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:'

sed -i '/^  channel:/d' "${ASSETS_DIR}/manifests/cvo-overrides.yaml"

#Remove Machines from manifests
rm -f ${ASSETS_DIR}/openshift/99_openshift-cluster-api_master-machines-*.yaml

#Remove MachineSets
rm -f ${ASSETS_DIR}/openshift/99_openshift-cluster-api_worker-machineset-*.yaml

#Make control-plane nodes unscheduable
sed -i "s;mastersSchedulable: true;mastersSchedulable: false;g" ${ASSETS_DIR}/manifests/cluster-scheduler-02-config.yml

#Create Ignition Configs
echo "Creating ignition-configs"
TF_LOG=debug openshift-install --dir=${ASSETS_DIR} create ignition-configs --log-level=debug 2>&1 | grep --line-buffered -v 'password\|X-Auth-Token\|UserData:' &
wait "$!"

INFRA_ID=$(sed -n 's|.*"infraID":"\([^"]*\)".*|\1|p' ${ASSETS_DIR}/metadata.json )
cat <<< "$INFRA_ID"   > "${SHARED_DIR}/INFRA_ID"

# Create a ramdisk for the etcd storage.  ipi-conf-openstack-precheckThis helps with disk latency
# unpredictability in the OpenStack cloud used by the CI
python -c \
    'import json, sys; j = json.load(sys.stdin); j[u"systemd"] = {}; j[u"systemd"][u"units"] = [{u"contents": "[Unit]\nDescription=Mount etcd as a ramdisk\nBefore=local-fs.target\n[Mount]\n What=none\nWhere=/var/lib/etcd\nType=tmpfs\nOptions=size=2G\n[Install]\nWantedBy=local-fs.target", u"enabled": True, u"name":u"var-lib-etcd.mount"}]; json.dump(j, sys.stdout)' \
    < "${ASSETS_DIR}/master.ign" \
    > "${ASSETS_DIR}/master.ign.out"
mv "${ASSETS_DIR}/master.ign.out" "${ASSETS_DIR}/master.ign"

#Prepare bootstrap.ign
python -c "import base64
import json
import os
import sys


with open(sys.argv[1], 'r') as f:
    ignition = json.load(f)

storage = ignition.get('storage', {})
files = storage.get('files', [])

infra_id = os.environ.get('INFRA_ID', 'openshift').encode()
hostname_b64 = base64.standard_b64encode(infra_id + b'-bootstrap\n').decode().strip()
files.append(
{
    'path': '/etc/hostname',
    'mode': 420,
    'contents': {
        'source': 'data:text/plain;charset=utf-8;base64,' + hostname_b64,
    },
})

ca_cert_path = os.environ.get('OS_CACERT', '')
if ca_cert_path:
    with open(ca_cert_path, 'r') as f:
        ca_cert = f.read().encode().strip()
        ca_cert_b64 = base64.standard_b64encode(ca_cert).decode().strip()

    files.append(
    {
        'path': '/opt/openshift/tls/cloud-ca-cert.pem',
        'mode': 420,
        'contents': {
            'source': 'data:text/plain;charset=utf-8;base64,' + ca_cert_b64,
        },
    })

storage['files'] = files
ignition['storage'] = storage

with open(sys.argv[1], 'w') as f:
    json.dump(ignition, f)

" ${ASSETS_DIR}/bootstrap.ign
# upload bootstrap.ign to glance

BOOTSTRAP_IGN_PATH=${ASSETS_DIR}/bootstrap.ign
GLANCE_SHIM_IMAGE_ID=$(openstack image create --disk-format raw --container-format bare --file ${BOOTSTRAP_IGN_PATH} "${INFRA_ID}"-bootstrap-ignition -f value -c id)
echo "$GLANCE_SHIM_IMAGE_ID" > "${SHARED_DIR}"/DELETE_IMAGES
FILE_LOCATION=$(openstack image show "${GLANCE_SHIM_IMAGE_ID}" | grep -oh "\/.*file")
GLANCE_ADDRESS=$(openstack catalog show glance -f table -c endpoints  | grep public | awk '{print $4}')
GLANCE_IMAGE_URL="$GLANCE_ADDRESS$FILE_LOCATION"

# Create Hostname Config Ignition File
DATA=$(echo "$INFRA_ID-bootstrap" | base64)
HOSTNAME_CONFIG_DATA_URL="data:text/plain;base64,$DATA"

#create Bootstrap Ignition Shim
OPENSTACK_TOKEN=$(openstack token issue --format value -c id)
cat > ${ASSETS_DIR}/"$INFRA_ID"-bootstrap-ignition.json << EOF
{
  "ignition": {
    "config": {
      "merge": [
        {
          "source": "$GLANCE_IMAGE_URL",
          "httpHeaders": [
            {
              "name": "X-Auth-Token",
              "value": "$OPENSTACK_TOKEN"
            }
          ]
        }
      ]
    },
  "version": "3.1.0"
  },
  "storage": {
    "files": [{
      "path": "/etc/hostname",
      "mode": 420,
      "contents": { "source": "$HOSTNAME_CONFIG_DATA_URL" }
    }]
  }
}
EOF


#Create master.ign for each master
MASTER_IGN_PATH=${ASSETS_DIR}/master.ign
for index in $(seq 0 2); do
    MASTER_HOSTNAME="$INFRA_ID-master-$index\n"
    python -c "import base64, json, sys;
ignition = json.load(sys.stdin);
storage = ignition.get('storage', {});
files = storage.get('files', []);
files.append({'path': '/etc/hostname', 'mode': 420, 'contents': {'source': 'data:text/plain;charset=utf-8;base64,' + base64.standard_b64encode(b'$MASTER_HOSTNAME').decode().strip()}});
storage['files'] = files;
ignition['storage'] = storage
json.dump(ignition, sys.stdout)
" <$MASTER_IGN_PATH >"${ASSETS_DIR}/$INFRA_ID-master-$index-ignition.json"
  done


# We need to archive the ASSETS_DIR for later steps. But we don't need log files
rm -rf ${ASSETS_DIR}/.openshift_install.log
tar -czf "${SHARED_DIR}"/assetsdir.tgz -C ${ASSETS_DIR} .

# We also need the metadata.json to be available to other steps
cp ${ASSETS_DIR}/metadata.json "${SHARED_DIR}"

