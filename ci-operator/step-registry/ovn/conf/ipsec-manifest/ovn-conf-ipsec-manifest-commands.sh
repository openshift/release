#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

cp "${CLUSTER_PROFILE_DIR}/pull-secret" /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret "${RELEASE_IMAGE_LATEST}" --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $1}' )
ocp_minor_version=$( echo "${ocp_version}" | awk --field-separator=. '{print $2}' )

cat >> "${SHARED_DIR}/manifest_cluster-network-03-config.yml" << EOF
apiVersion: operator.openshift.io/v1
kind: Network
metadata:
  creationTimestamp: null
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  externalIP:
    policy: {}
  networkType: OVNKubernetes
  serviceNetwork:
  - 172.30.0.0/16
  defaultNetwork:
    type: OVNKubernetes
    ovnKubernetesConfig:
      ipsecConfig: {}
EOF

# adapt to newer ipsec config for ocp versions >= 4.15
if (( ocp_minor_version >= 15 && ocp_major_version == 4 )); then
    /tmp/yq e '.spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig.mode = "Full"' -i ${SHARED_DIR}/manifest_cluster-network-03-config.yml

  # If the IPSEC_RHCOS_LAYERED_IMAGE environment variable is not empty, then apply the custom layered image which is used for pre-merge testing libreswan
  # If the IPSEC_RHCOS_LAYERED_IMAGE environment variable is empty, then do thing.
  if [[ -n "${IPSEC_RHCOS_LAYERED_IMAGE}" ]]; then
     echo "IPSEC_RHCOS_LAYERED_IMAGE is ${IPSEC_RHCOS_LAYERED_IMAGE}" 
     for role in master worker; do
  cat >> "${SHARED_DIR}/manifest_${role}-ipsec-extension.yml" <<-EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${role}
  annotations:
    user-ipsec-machine-config: "true"
  name: 80-ipsec-${role}-extensions
spec:
  osImageURL: ${IPSEC_RHCOS_LAYERED_IMAGE}
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - name: ipsecenabler.service
        enabled: true
        contents: |
         [Unit]
         Description=Enable ipsec service after os extension installation
         Before=kubelet.service

         [Service]
         Type=oneshot
         ExecStartPre=systemd-tmpfiles --create /usr/lib/rpm-ostree/tmpfiles.d/libreswan.conf
         ExecStart=systemctl enable --now ipsec.service

         [Install]
         WantedBy=multi-user.target
EOF
    cat ${SHARED_DIR}/manifest_${role}-ipsec-extension.yml
    done
  fi 
fi

cat ${SHARED_DIR}/manifest_cluster-network-03-config.yml

# additional os extension for 4.14 only
if (( ocp_minor_version == 14 && ocp_major_version == 4 )); then
    for role in master worker; do
cat >> "${SHARED_DIR}/manifest_${role}-ipsec-extension.yml" <<-EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: $role
  name: 80-$role-extensions
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
      - name: ipsecenabler.service
        enabled: true
        contents: |
         [Unit]
         Description=Enable ipsec service after os extension installation
         Before=kubelet.service

         [Service]
         Type=oneshot
         ExecStart=systemctl enable --now ipsec.service

         [Install]
         WantedBy=multi-user.target
  extensions:
    - ipsec
EOF
    cat ${SHARED_DIR}/manifest_${role}-ipsec-extension.yml
    done
fi
