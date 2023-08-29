#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset
# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR
# Save exit code for must-gather to generate junit
trap 'echo "$?" > "${SHARED_DIR}/install-status.txt"' EXIT TERM ERR

[ -z "${AUX_HOST}" ] && { echo "\$AUX_HOST is not filled. Failing."; exit 1; }
[ -z "${PROVISIONING_HOST}" ] && { echo "\$PROVISIONING_HOST is not filled. Failing."; exit 1; }

function oinst() {
  /tmp/openshift-baremetal-install --dir="${INSTALL_DIR}" --log-level=debug "${@}" 2>&1 | grep\
   --line-buffered -v 'password\|X-Auth-Token\|UserData:' || return 0
}

echo "[INFO] Initializing..."

PULL_SECRET_PATH=${CLUSTER_PROFILE_DIR}/pull-secret
INSTALL_DIR="/tmp/installer"

echo "[INFO] Installing from initial release ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}..."
echo "[INFO] Extracting the baremetal-installer from ${MULTI_RELEASE_IMAGE}..."

# The extraction may be done from the release-multi-latest image, so that we can extract the openshift-baremetal-install
# based on the runner architecture. We might need to change this in the future if we want to ship different versions of
# the installer for different architectures in the same single-arch payload (and then support using a remote libvirt uri
# for the provisioning host).
oc adm release extract -a "$PULL_SECRET_PATH" "${MULTI_RELEASE_IMAGE}" \
   --command=openshift-baremetal-install --to=/tmp

if [ "${DISCONNECTED}" == "true" ]; then
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="$(<"${CLUSTER_PROFILE_DIR}/mirror_registry_url")/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
fi
file /tmp/openshift-baremetal-install

echo "[INFO] Processing the install-config.yaml..."
# Patching the cluster_name again as the one set in the ipi-conf ref is using the ${UNIQUE_HASH} variable, and
# we might exceed the maximum length for some entity names we define
# (e.g., hostname, NFV-related interface names, etc...)

pull_secret=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")

cat <<EOF > "$SHARED_DIR/install-config.yaml"
---
apiVersion: v1
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    baremetal: {}
  replicas: 3
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 0
metadata:
  name: test-cluster
platform:
  baremetal:
    apiVIP: 10.1.235.202
    ingressVIP: 10.1.235.203
    hosts:
    - name: master-00
      role: master
      bmc:
        address: redfish-virtualmedia://10.1.233.74/redfish/v1/Systems/1
        disableCertificateVerification: true
        username: Administrator
        password: Administrator
      rootDeviceHints:
        hctl: 2:0:0:0
    - name: master-01
      role: master
      bmc:
        address: redfish-virtualmedia://10.1.233.75/redfish/v1/Systems/1
        disableCertificateVerification: true
        username: Administrator
        password: Administrator
      bootMACAddress: b4:7a:f1:36:ba:20
      rootDeviceHints:
        hctl: 2:0:0:0
    - name: master-02
      role: master
      bmc:
        address: redfish-virtualmedia://10.1.233.79/redfish/v1/Systems/1
        disableCertificateVerification: true
        username: Administrator
        password: Administrator
      bootMACAddress: 94:40:c9:f8:b7:68
      rootDeviceHints:
        hctl: 2:0:0:0
pullSecret: >
  ${pull_secret}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
  machineNetwork:
  - cidr: 10.1.235.0/24
  - cidr: 2620:0052:0000:01eb::/64
  networkType: OVNKubernetes
publish: External
baseDomain: qe.devcluster.openshift.com
sshKey: ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCWkwurd8TNAi+D7ffvyDdhGBSQtJx3/Yedlwvvha0q772vLlOAGlKCw4dajKy6qty1/GGQDgTJ17h3C9TEArI8ZqILnyydeY56DL+ELN3dtGBVof/N2qtW0+SmEnd1Mi7Qy5Tx4e/GVmB3NgX9szwNOVXhebzgBsXc9x+RtCVLPLC8J+qqSdTUZ0UfJsh2ptlQLGHmmTpF//QlJ1tngvAFeCOxJUhrLAa37P9MtFsiNk31EfKyBk3eIdZljTERmqFaoJCohsFFEdO7tVgU6p5NwniAyBGZVjZBzjELoI1aZ+/g9yReIScxl1R6PWqEzcU6lGo2hInnb6nuZFGb+90D
  openshift-qe@redhat.com
EOF

mkdir -p "${INSTALL_DIR}"
cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"
# From now on, we assume no more patches to the install-config.yaml are needed.
# We can create the installation dir with the manifests and, finally, the ignition configs

# Also get a sanitized copy of the install-config.yaml as an artifact for debugging purposes
grep -v "password\|username\|pullSecret" "${SHARED_DIR}/install-config.yaml" > "${ARTIFACT_DIR}/install-config.yaml"

### Create manifests
echo "[INFO] Creating manifests..."
oinst create manifests

echo "[INFO] Check that missing BootMACAddress validation is enforced"
grep -q 'BootMACAddress: Required value: missing BootMACAddress' "${INSTALL_DIR}/.openshift_install.log"

cat <<EOF > "$SHARED_DIR/install-config.yaml"
---
apiVersion: v1
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    baremetal: {}
  replicas: 3
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 0
metadata:
  name: test-cluster
platform:
  baremetal:
    apiVIP: 10.1.235.202
    ingressVIP: 10.1.235.203
    hosts:
    - name: master-00
      role: master
      bmc:
        address: ipmi://10.1.233.74
        disableCertificateVerification: true
        username: Administrator
        password: Administrator
      bootMACAddress: b4:7a:f1:32:d7:80
      bootMode: UEFISecureBoot
      rootDeviceHints:
        hctl: 2:0:0:0
    - name: master-01
      role: master
      bmc:
        address: redfish-virtualmedia://10.1.233.75/redfish/v1/Systems/1
        disableCertificateVerification: true
        username: Administrator
        password: Administrator
      bootMACAddress: b4:7a:f1:36:ba:20
      rootDeviceHints:
        hctl: 2:0:0:0
    - name: master-02
      role: master
      bmc:
        address: redfish-virtualmedia://10.1.233.79/redfish/v1/Systems/1
        disableCertificateVerification: true
        username: Administrator
        password: Administrator
      bootMACAddress: 94:40:c9:f8:b7:68
      rootDeviceHints:
        hctl: 2:0:0:0
pullSecret: >
  ${pull_secret}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
  machineNetwork:
  - cidr: 10.1.235.0/24
  - cidr: 2620:0052:0000:01eb::/64
  networkType: OVNKubernetes
publish: External
baseDomain: qe.devcluster.openshift.com
sshKey: ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCWkwurd8TNAi+D7ffvyDdhGBSQtJx3/Yedlwvvha0q772vLlOAGlKCw4dajKy6qty1/GGQDgTJ17h3C9TEArI8ZqILnyydeY56DL+ELN3dtGBVof/N2qtW0+SmEnd1Mi7Qy5Tx4e/GVmB3NgX9szwNOVXhebzgBsXc9x+RtCVLPLC8J+qqSdTUZ0UfJsh2ptlQLGHmmTpF//QlJ1tngvAFeCOxJUhrLAa37P9MtFsiNk31EfKyBk3eIdZljTERmqFaoJCohsFFEdO7tVgU6p5NwniAyBGZVjZBzjELoI1aZ+/g9yReIScxl1R6PWqEzcU6lGo2hInnb6nuZFGb+90D
  openshift-qe@redhat.com
EOF

cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"

### Create manifests
echo "[INFO] Creating manifests..."
oinst create manifests

echo "[INFO] Check that ipmi does not support UEFI secure boot validation is enforced"
grep -q 'driver ipmi does not support UEFI secure boot' "${INSTALL_DIR}/.openshift_install.log"

cat <<EOF > "$SHARED_DIR/install-config.yaml"
---
apiVersion: v1
controlPlane:
  architecture: amd64
  hyperthreading: Enabled
  name: master
  platform:
    baremetal: {}
  replicas: 3
compute:
- architecture: amd64
  hyperthreading: Enabled
  name: worker
  platform: {}
  replicas: 0
metadata:
  name: test-cluster
platform:
  baremetal:
    apiVIP: 10.1.235.202
    ingressVIP: 10.1.235.203
    hosts:
    - name: master-00
      role: master
      bmc:
        address: redfish://10.1.233.74/redfish/v1/Systems/1
        disableCertificateVerification: true
        username: Administrator
        password: Administrator
      bootMACAddress: b4:7a:f1:32:d7:80
      bootMode: UEFISecureBoot
      rootDeviceHints:
        hctl: 2:0:0:0
    - name: master-01
      role: master
      bmc:
        address: redfish-virtualmedia://10.1.233.75/redfish/v1/Systems/1
        disableCertificateVerification: true
        username: Administrator
        password: Administrator
      bootMACAddress: b4:7a:f1:36:ba:20
      rootDeviceHints:
        hctl: 2:0:0:0
    - name: master-02
      role: master
      bmc:
        address: redfish-virtualmedia://10.1.233.79/redfish/v1/Systems/1
        disableCertificateVerification: true
        username: Administrator
        password: Administrator
      bootMACAddress: 94:40:c9:f8:b7:68
      rootDeviceHints:
        hctl: 2:0:0:0
    provisioningNetwork: Disabled
pullSecret: >
  ${pull_secret}
networking:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  serviceNetwork:
  - 172.30.0.0/16
  machineNetwork:
  - cidr: 10.1.235.0/24
  - cidr: 2620:0052:0000:01eb::/64
  networkType: OVNKubernetes
publish: External
baseDomain: qe.devcluster.openshift.com
sshKey: ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCWkwurd8TNAi+D7ffvyDdhGBSQtJx3/Yedlwvvha0q772vLlOAGlKCw4dajKy6qty1/GGQDgTJ17h3C9TEArI8ZqILnyydeY56DL+ELN3dtGBVof/N2qtW0+SmEnd1Mi7Qy5Tx4e/GVmB3NgX9szwNOVXhebzgBsXc9x+RtCVLPLC8J+qqSdTUZ0UfJsh2ptlQLGHmmTpF//QlJ1tngvAFeCOxJUhrLAa37P9MtFsiNk31EfKyBk3eIdZljTERmqFaoJCohsFFEdO7tVgU6p5NwniAyBGZVjZBzjELoI1aZ+/g9yReIScxl1R6PWqEzcU6lGo2hInnb6nuZFGb+90D
  openshift-qe@redhat.com
EOF

cp "${SHARED_DIR}/install-config.yaml" "${INSTALL_DIR}/"

### Create manifests
echo "[INFO] Creating manifests..."
oinst create manifests
oinst create cluster

echo "[INFO] Check that driver redfish requires provisioning network validation is enforced"
grep -q 'driver redfish requires provisioning network' "${INSTALL_DIR}/.openshift_install.log"
