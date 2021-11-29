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

# Ensure ignition assets are configured with the correct invoker to track CI jobs.
export OPENSHIFT_INSTALL_INVOKER="openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}"
export TEST_PROVIDER='packet'
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${RELEASE_IMAGE_LATEST}"

# The oc binary is placed in the shared-tmp by the test container and we want to use
# that oc for all actions.
export PATH=${SHARED_DIR}:${PATH}

cp "$(command -v openshift-install)" ${SHARED_DIR}
echo "Installing from release ${RELEASE_IMAGE_LATEST}"

EXPIRATION_DATE=$(date -d '4 hours' --iso=minutes --utc)
BASE_DOMAIN="origin-ci-int-aws.dev.rhcloud.com"
CLUSTER_NAME=${NAMESPACE}-${JOB_NAME_HASH}
PACKET_PROJECT_ID=$(cat "${CLUSTER_PROFILE_DIR}/packet-project-id")
MATCHBOX_CLIENT_KEY="/var/run/cluster-secrets-metal/matchbox-client.key"
MATCHBOX_CLIENT_CERT="/var/run/cluster-secrets-metal/matchbox-client.crt"

export EXPIRATION_DATE
export BASE_DOMAIN
export CLUSTER_NAME
export PACKET_PROJECT_ID
export MATCHBOX_CLIENT_KEY
export MATCHBOX_CLIENT_CERT

workers=3
if [[ "${CLUSTER_VARIANT}" =~ "compact" ]]; then
  workers=0
fi
mkdir ${SHARED_DIR}/installer
cp ${SHARED_DIR}/install-config.yaml ${SHARED_DIR}/installer
ls ${SHARED_DIR}
cat >> ${SHARED_DIR}/installer/matchbox-trusted-bundle.crt <<EOF
-----BEGIN CERTIFICATE-----
MIIFGDCCAwCgAwIBAgIUMcQ9HOev3PFJ0+mLyH384yQJokUwDQYJKoZIhvcNAQEL
BQAwEjEQMA4GA1UEAwwHZmFrZS1jYTAeFw0yMDA0MDExOTQ0MTdaFw0zMDAzMzAx
OTQ0MTdaMBIxEDAOBgNVBAMMB2Zha2UtY2EwggIiMA0GCSqGSIb3DQEBAQUAA4IC
DwAwggIKAoICAQDdWuSbpIV2vT97Zih//kupKbNmM6IOLjdaP1Dwq3u/DzwbcCdG
+4F/nXuRXeIpeyWYZkE2kODNRVD7/R/4U1l45K++0nVsg1MXbUzN7gOtzs0yT11N
sCD+YRyWoBRK3w2cb7wbmKKG3i3bA5uuWRBnNjSzSB71y6A1oxpFLhVTZNSumtOd
Ujc68occ5p7r3scbc/qQwFuEHhjBLdJA2rIh4djOj0gXFT5U95Bfp9AygdmjA5B6
45X8xXCH6yN0IDG1gxNLqjmCvT9A5sJyRD4NErN2LRIUn2WaS1xroqPi1ksuORuK
IdFwvCVJZ41pwtv/6oZmR2RZ/KS3C3iDygCRlamY06kdKPxEXuvy3Y9eEsnhkdSk
87QvBgMYAqwHAvWLuwfxsHsF15pxCG+nF39hF9tnH2Uxrd9i+3n7xyDXNxFOpnFv
3WVL31Pw9P797rVUntiK4eKc5bztjtfcMez9bfArqNPvBUZ/QgJ4kx2i25beiaW7
yWVXo7ZEexb50FzKV37xggAkf8e1rJ/ZKVstF7B2tsGT/jtEIHLLN7cOGofthQY7
k5S8N5cwlscKR6cGkpPOeylwDnxVZc0KbeHmVj4fAds1NvExblITTULG5aMbzyS+
NPzIyzTGP3QfDPfTIVosdtke0OzxgkRvVd02ps/UTW+JC5alH/RBqVfHdwIDAQAB
o2YwZDAdBgNVHQ4EFgQU5FnCPHCrqd4vs9819itLjcU1bFcwHwYDVR0jBBgwFoAU
5FnCPHCrqd4vs9819itLjcU1bFcwEgYDVR0TAQH/BAgwBgEB/wIBADAOBgNVHQ8B
Af8EBAMCAYYwDQYJKoZIhvcNAQELBQADggIBANdEhWRNjJJqu3L3xEXIPumv49Or
Uhmsmv7LyCrE4Dkv7h5SiAfDe1t6T4IM1Uw7Zy9X2af2sOzUdm4wnkIw5srtSwmF
Grw0GzLt4/v6guM/Tv8x37Knif2oNLOedjHLvRQfknTkTiZ6FXPS1eO/LZOuqeFM
e4x+Az0O1aH/v1f6CdawXLc+grzZawX8hRrPxvXsmLY1zYbCrG3CzlyDfBKAhQWP
ZTum+mlUvrxgK5cttZ23k5d45vz/IIoB4O4PFQ588BLt2MGrylWgCqWvvJK8NzJE
RhSAhAk04fuPOHoOrZT7UAw1ecnPf6yiHkErqEOc0mLzR4RTPMWrJE6tO1ySG3Cr
vxvCvg7dcYYMZfbggG0jqvDIFoMqdP8DQG2JnaqmkNYUa2S2tNaXG/t/7/ybtD67
Wo6xCoLXy4l91ftXz2Q/eIi2fpm4Q7Y+RIQw8E7uDjHvNyKnILlLV5FsaEo9YZgT
/LjWWHwX/fSML8qwAj/QzRNqPjiSs4suPENhPWoEkByTzImryWmhX8kEFThjWiZb
QNDtcNi8j1XaJAXkJHdMgqKIlzOuXN2H4CKaTm0NFhIGr7hnApZ+gwVvqn8ftUw8
n/4Cz8FqvbNh1HLdnSjCiJ0O0pR6L4dcOgVujtY4MvAv2FXVRi2MKp9aim/PogGT
n/gYNEejzkRn3Xx9
-----END CERTIFICATE-----
EOF

echo "$(date +%s)" >> "${SHARED_DIR}/CLUSTER_INSTALL_START_TIME"
openshift-install --dir=${SHARED_DIR}/installer/ create manifests &
wait "$!"

sed -i '/^  channel:/d' ${SHARED_DIR}/installer/manifests/cvo-overrides.yaml

# TODO: Replace with a more concise manifest injection approach
# if [[ -z "${CLUSTER_NETWORK_MANIFEST}" ]]; then
#     echo "${CLUSTER_NETWORK_MANIFEST}" > ${SHARED_DIR}/installer/manifests/cluster-network-03-config.yml
# fi

cat >> ${SHARED_DIR}/installer/openshift/99_kernelargs_e2e_metal.yaml << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: "master"
  name: 99-kernelargs-e2e-metal
spec:
  kernelArguments:
    - 'console=tty0'
    - 'console=ttyS1,115200n8'
    - 'rd.neednet=1'
EOF

openshift-install --dir=${SHARED_DIR}/installer create ignition-configs

mkdir ${SHARED_DIR}/terraform
cp -r /var/lib/openshift-install/upi/metal/* ${SHARED_DIR}/terraform/
cp /bin/terraform-provider-matchbox ${SHARED_DIR}/terraform/

if openshift-install coreos print-stream-json 2>/tmp/err.txt >/tmp/coreos-print-stream.json; then
  RHCOS_JSON_FILE="/tmp/coreos-print-stream.json"
  PXE_INITRD_URL="$(jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.initramfs.location' "${RHCOS_JSON_FILE}")"
  PXE_KERNEL_URL="$(jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.kernel.location' "${RHCOS_JSON_FILE}")"
  PXE_OS_IMAGE_URL="$(jq -r '.architectures.x86_64.artifacts.metal.formats."raw.gz".disk.location' "${RHCOS_JSON_FILE}")"
  PXE_ROOTFS_URL="$(jq -r '.architectures.x86_64.artifacts.metal.formats.pxe.rootfs.location' "${RHCOS_JSON_FILE}")"
else
  RHCOS_JSON_FILE="/var/lib/openshift-install/rhcos.json"
  BASE_URI="$(jq -r '.baseURI' "${RHCOS_JSON_FILE}" | sed 's|https://|http://|' | sed 's|rhcos-redirector.apps.art.xq1c.p1.openshiftapps.com|releases-art-rhcos.svc.ci.openshift.org|')"
  PXE_INITRD_URL="${BASE_URI}$(jq -r '.images["live-initramfs"].path // .images["initramfs"].path' "${RHCOS_JSON_FILE}")"
  PXE_KERNEL_URL="${BASE_URI}$(jq -r '.images["live-kernel"].path // .images["kernel"].path' "${RHCOS_JSON_FILE}")"
  PXE_OS_IMAGE_URL="${BASE_URI}$(jq -r '.images["metal-bios"].path // .images["metal"].path' "${RHCOS_JSON_FILE}")"
  PXE_ROOTFS_URL="${BASE_URI}$(jq -r '.images["live-rootfs"].path' "${RHCOS_JSON_FILE}")"
fi
if [[ $PXE_KERNEL_URL =~ "live" ]]; then
  PXE_KERNEL_ARGS="coreos.live.rootfs_url=${PXE_ROOTFS_URL}"
else
  PXE_KERNEL_ARGS="coreos.inst.image_url=${PXE_OS_IMAGE_URL}"
fi
# 4.3 unified 'metal-bios' and 'metal-uefi' into just 'metal', unused in 4.6
cat >> ${SHARED_DIR}/terraform/terraform.tfvars << EOF
cluster_id = "${CLUSTER_NAME}"
bootstrap_ign_file = "${SHARED_DIR}/installer/bootstrap.ign"
cluster_domain = "${CLUSTER_NAME}.${BASE_DOMAIN}"
master_count = "3"
master_ign_file = "${SHARED_DIR}/installer/master.ign"
matchbox_client_cert = "${MATCHBOX_CLIENT_CERT}"
matchbox_client_key = "${MATCHBOX_CLIENT_KEY}"
matchbox_http_endpoint = "http://http-matchbox.apps.build01.ci.devcluster.openshift.com"
matchbox_rpc_endpoint = "a3558a943132041b48b20a67aa291d99-23796056.us-east-1.elb.amazonaws.com:8081"
matchbox_trusted_ca_cert = "${SHARED_DIR}/installer/matchbox-trusted-bundle.crt"
packet_project_id = "${PACKET_PROJECT_ID}"
packet_plan = "${PACKET_PLAN}"
packet_facility = "${PACKET_FACILITY}"
packet_hardware_reservation_id = "${PACKET_HARDWARE_RESERVATION_ID}"
public_r53_zone = "${BASE_DOMAIN}"
pxe_initrd_url = "${PXE_INITRD_URL}"
pxe_kernel_url = "${PXE_KERNEL_URL}"
pxe_os_image_url = "${PXE_OS_IMAGE_URL}"
pxe_kernel_args = "${PXE_KERNEL_ARGS}"
worker_count = "${workers}"
worker_ign_file = "${SHARED_DIR}/installer/worker.ign"
EOF

PACKET_AUTH_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/packet-auth-token")
export PACKET_AUTH_TOKEN

echo "Creating resources using terraform"
(cd ${SHARED_DIR}/terraform && terraform init)

rc=1
(cd ${SHARED_DIR}/terraform && terraform apply -auto-approve) && rc=0
if test "${rc}" -eq 1; then echo "failed to create the infra resources"; exit 1; fi

echo "Waiting for bootstrap to complete"
rc=1
openshift-install wait-for bootstrap-complete &

set +e
wait "$!"
ret="$?"
set -e

if [ "$ret" -ne 0 ]; then
  echo "failed to bootstrap"
  pushd ${SHARED_DIR}/terraform
  GATHER_BOOTSTRAP_ARGS="--bootstrap $(terraform output -json | jq -r ".bootstrap_ip.value")"
  for ip in $(terraform output -json | jq -r ".master_ips.value[]")
  do
    GATHER_BOOTSTRAP_ARGS="${GATHER_BOOTSTRAP_ARGS} --master=${ip}"
  done
  popd
  openshift-install --dir=${SHARED_DIR}/installer gather bootstrap ${GATHER_BOOTSTRAP_ARGS}
  mv log-bundle* ${ARTIFACT_DIR}
  exit 1
fi

echo "Removing bootstrap host from control plane api pool"
(cd ${SHARED_DIR}/terraform && terraform apply -auto-approve=true -var=bootstrap_dns="false")

function approve_csrs() {
  while [[ ! -f ${SHARED_DIR}/setup-failed ]] && [[ ! -f ${SHARED_DIR}/setup-success ]]; do
    oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
    sleep 15
  done
}

function update_image_registry() {
  while true; do
    sleep 10;
    oc get configs.imageregistry.operator.openshift.io/cluster > /dev/null && break
  done
  oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
}

approve_csrs &
update_image_registry &

echo "Completing UPI setup"
openshift-install --dir=${SHARED_DIR}/installer wait-for install-complete 2>&1 | grep --line-buffered -v password &
wait "$!"

# Password for the cluster gets leaked in the installer logs and hence removing them.
sed '
  s/password: .*/password: REDACTED/g;
  s/X-Auth-Token.*/X-Auth-Token REDACTED/g;
  s/UserData:.*,/UserData: REDACTED,/g;
  ' "${SHARED_DIR}/installer/.openshift_install.log" > "${ARTIFACT_DIR}/.openshift_install.log"

echo "$(date +%s)" >> "${SHARED_DIR}/TEST_TIME_INSTALL_END"
date "+%F %X" >> "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

cp -t "${SHARED_DIR}" \
    "${SHARED_DIR}/installer/auth/kubeconfig"