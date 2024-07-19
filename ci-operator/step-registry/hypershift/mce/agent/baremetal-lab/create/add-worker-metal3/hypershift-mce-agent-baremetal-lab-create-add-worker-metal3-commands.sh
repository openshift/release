#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ add-workers metal3 command ************"

HOSTED_CLUSTER_NAME="$(echo -n "$PROW_JOB_ID" | sha256sum | cut -c-20)"
HOSTED_CLUSTER_NAME_NS=HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -o=jsonpath="{.items[?(@.metadata.name=='$CLUSTER_NAME')].metadata.namespace}")
BASE_DOMAIN=$(<"${CLUSTER_PROFILE_DIR}/base_domain")

mkdir -p "$SHARED_DIR/bmh-manifests/"
pushd $SHARED_DIR/bmh-manifests

oc create -f - <<EOF
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: ${HOSTED_CLUSTER_NAME}
  namespace: ${HOSTED_CLUSTER_NAME_NS}
spec:
  cpuArchitecture: ${ADDITIONAL_WORKER_ARCHITECTURE}
  pullSecretRef:
    name: pull-secret
  sshAuthorizedKey: $(<"${SHARED_DIR}/ssh-public-key")
EOF

# shellcheck disable=SC2154
for bmhost in $(yq e -o=j -I=0 '.[]' "${SHARED_DIR}/hosts.yaml"); do
  # shellcheck disable=SC1090
  . <(echo "$bmhost" | yq e 'to_entries | .[] | (.key + "=\"" + .value + "\"")')
  # shellcheck disable=SC2154
  if [ ${#name} -eq 0 ] || [ ${#ip} -eq 0 ] || [ ${#ipv6} -eq 0 ]; then
    echo "Error when parsing the Bare Metal Host metadata"
    exit 1
  fi

  # We use the additional workers implemented for heterogeneous clusters as nodes for the hypershift hosted cluster
  # TODO: do this better
  if ! [[ "$name" =~ worker-a-* ]]; then
    continue
  fi
  oc create -f <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${name}-bmc-secret
  namespace: ${HOSTED_CLUSTER_NAME_NS}
type: Opaque
data:
  username: ${redfish_user}
  password: ${redfish_password}
EOF
    oc create -f <<EOF
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: ${name}
  namespace: ${HOSTED_CLUSTER_NAME_NS}
  labels:
    infraenvs.agent-install.openshift.io: ${HOSTED_CLUSTER_NAME}
  annotations:
    bmac.agent-install.openshift.io/hostname: ${name}.${CLUSTER_NAME}.${BASE_DOMAIN}
spec:
  online: true
  bootMACAddress: ${mac}
  rootDeviceHints:
    ${root_device:+deviceName: ${root_device}}
    ${root_dev_hctl:+hctl: ${root_dev_hctl}}
  bmc:
    address: ${redfish_scheme}://${bmc_address}${redfish_base_uri}
    disableCertificateVerification: true
    credentialsName: ${name}-bmc-secret
  networkConfig:
    interfaces:
    - name: ${baremetal_iface}
      type: ethernet
      state: up
      ipv4:
        enabled: true
        dhcp: true
      ipv6:
        enabled: true
        dhcp: true
EOF
done