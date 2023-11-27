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

openshift_install_path="/var/lib/openshift-install"

SUBNETS_CONFIG=/var/run/vault/vsphere-config/subnets.json

# shellcheck source=/dev/null
declare vsphere_datacenter
declare vsphere_datastore
declare vsphere_cluster
declare dns_server
declare vsphere_url
declare vlanid
declare primaryrouterhostname
declare vsphere_portgroup
source "${SHARED_DIR}/vsphere_context.sh"

if [[ ${vsphere_portgroup} == *"segment"* ]]; then
  third_octet=$(grep -oP '[ci|qe\-discon]-segment-\K[[:digit:]]+' <(echo "${vsphere_portgroup}"))

  machine_cidr="192.168.${third_octet}.0/25"
  netmask="255.255.255.128"
  gateway="192.168.${third_octet}.1"
  bootstrap_ip_address="192.168.${third_octet}.3"
  lb_ip_address="192.168.${third_octet}.2"

  read -r compute_ip_addresses <<EOM
["192.168.${third_octet}.7","192.168.${third_octet}.8","192.168.${third_octet}.9"]
EOM

  read -r control_plane_ip_addresses <<EOM
["192.168.${third_octet}.4","192.168.${third_octet}.5","192.168.${third_octet}.6"]
EOM
else

  if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
    echo "VLAN ID: ${vlanid} does not exist in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
    exit 1
  fi

  # ** NOTE: The first two addresses are not for use. [0] is the network, [1] is the gateway

  dns_server=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].dnsServer' "${SUBNETS_CONFIG}")
  gateway=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].gateway' "${SUBNETS_CONFIG}")
  netmask=$(jq -r --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].mask' "${SUBNETS_CONFIG}")

  lb_ip_address=$(jq -r --arg VLANID "$vlanid" --arg PRH "$primaryrouterhostname" '.[$PRH][$VLANID].ipAddresses[2]' "${SUBNETS_CONFIG}")
  bootstrap_ip_address=$(jq -r --arg VLANID "$vlanid" --arg PRH "$primaryrouterhostname" '.[$PRH][$VLANID].ipAddresses[3]' "${SUBNETS_CONFIG}")
  machine_cidr=$(jq -r --arg VLANID "$vlanid" --arg PRH "$primaryrouterhostname" '.[$PRH][$VLANID].machineNetworkCidr' "${SUBNETS_CONFIG}")

  printf "***** DEBUG %s %s %s %s ******\n" "$dns_server" "$lb_ip_address" "$bootstrap_ip_address" "$machine_cidr"

  control_plane_idx=0
  control_plane_addrs=()
  control_plane_hostnames=()
  for n in {4..6}; do
    control_plane_addrs+=("$(jq -r --argjson N "$n" --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")")
    control_plane_hostnames+=("control-plane-$((control_plane_idx++))")
  done

  printf "**** DEBUG %s ******\n" "${control_plane_addrs[@]}"

  control_plane_ip_addresses="[${control_plane_ip_addresses%,}]"

  compute_idx=0
  compute_addrs=()
  compute_hostnames=()
  for n in {7..9}; do
    compute_addrs+=("$(jq -r --argjson N "$n" --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH][$VLANID].ipAddresses[$N]' "${SUBNETS_CONFIG}")")
    compute_hostnames+=("compute-$((compute_idx++))")
  done

  printf "**** DEBUG %s ******\n" "${compute_addrs[@]}"

  printf -v compute_ip_addresses "\"%s\"," "${compute_addrs[@]}"
  compute_ip_addresses="[${compute_ip_addresses%,}]"

fi

# First one for api, second for apps.
echo "${lb_ip_address}" >>"${SHARED_DIR}"/vips.txt
echo "${lb_ip_address}" >>"${SHARED_DIR}"/vips.txt

export HOME=/tmp
export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${RELEASE_IMAGE_LATEST}
# Ensure ignition assets are configured with the correct invoker to track CI jobs.
export OPENSHIFT_INSTALL_INVOKER=openshift-internal-ci/${JOB_NAME_SAFE}/${BUILD_ID}

echo "$(date -u --rfc-3339=seconds) - Creating reusable variable files..."
# Create basedomain.txt
echo "vmc-ci.devcluster.openshift.com" >"${SHARED_DIR}"/basedomain.txt
base_domain=$(<"${SHARED_DIR}"/basedomain.txt)

# Create clustername.txt
echo "${NAMESPACE}-${UNIQUE_HASH}" >"${SHARED_DIR}"/clustername.txt
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)

# Create clusterdomain.txt
echo "${cluster_name}.${base_domain}" >"${SHARED_DIR}"/clusterdomain.txt
cluster_domain=$(<"${SHARED_DIR}"/clusterdomain.txt)

ssh_pub_key_path="${CLUSTER_PROFILE_DIR}/ssh-publickey"
install_config="${SHARED_DIR}/install-config.yaml"

legacy_installer_json="${openshift_install_path}/rhcos.json"
fcos_json_file="${openshift_install_path}/fcos.json"

if [[ -f "$fcos_json_file" ]]; then
  legacy_installer_json=$fcos_json_file
fi

# https://github.com/openshift/installer/blob/master/docs/user/overview.md#coreos-bootimages
# This code needs to handle pre-4.8 installers though too.
if openshift-install coreos print-stream-json 2>/tmp/err.txt >${SHARED_DIR}/coreos.json; then
  echo "Using stream metadata"
  ova_url=$(jq -r '.architectures.x86_64.artifacts.vmware.formats.ova.disk.location' <${SHARED_DIR}/coreos.json)
else
  if ! grep -qF 'unknown command \"coreos\"' /tmp/err.txt; then
    echo "Unhandled error from openshift-install" 1>&2
    cat /tmp/err.txt
    exit 1
  fi
  legacy_installer_json=/var/lib/openshift-install/rhcos.json
  echo "Falling back to parsing ${legacy_installer_json}"
  ova_url="$(jq -r '.baseURI + .images["vmware"].path' ${legacy_installer_json})"
fi
rm -f /tmp/err.txt

echo "${ova_url}" >"${SHARED_DIR}"/ova_url.txt
ova_url=$(<"${SHARED_DIR}"/ova_url.txt)

vm_template="${ova_url##*/}"

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

vsphere_version=$(govc about -json | jq -r .About.Version | awk -F'.' '{print $1}')

# select a hardware version for testing
hw_versions=(15 17 18 19)
if [[ ${vsphere_version} -eq 8 ]]; then
  hw_versions=(20)
fi

hw_available_versions=${#hw_versions[@]}
selected_hw_version_index=$((RANDOM % ${hw_available_versions}))
target_hw_version=${hw_versions[$selected_hw_version_index]}
echo "$(date -u --rfc-3339=seconds) - Selected hardware version ${target_hw_version}"
vm_template=${vm_template}-hw${target_hw_version}

echo "$(date -u --rfc-3339=seconds) - sourcing context from vsphere_context.sh..."
echo "export target_hw_version=${target_hw_version}" >>${SHARED_DIR}/vsphere_context.sh

echo "$(date -u --rfc-3339=seconds) - Extend install-config.yaml ..."

#set machine cidr if proxy is enabled
if grep 'httpProxy' "${install_config}"; then
  cat >>"${install_config}" <<EOF
networking:
  machineNetwork:
  - cidr: "$machine_cidr"
EOF
fi

# Create DNS files for nodes
if command -v pwsh &> /dev/null
then
  ROUTE53_CREATE_JSON='{"Comment": "Create public OpenShift DNS records for Nodes of VSphere UPI CI install", "Changes": []}'
  ROUTE53_DELETE_JSON='{"Comment": "Delete public OpenShift DNS records for Nodes of VSphere UPI CI install", "Changes": []}'
  DNS_RECORD='{
  "Action": "${ACTION}",
  "ResourceRecordSet": {
    "Name": "${CLUSTER_NAME}-${VM_NAME}.${CLUSTER_DOMAIN}.",
    "Type": "A",
    "TTL": 60,
    "ResourceRecords": [{"Value": "${IP_ADDRESS}"}]
    }
  }'

  for (( node=0; node < 3; node++)); do
    echo "Creating DNS entry for ${compute_hostnames[$node]}"
    node_record=$(echo "${DNS_RECORD}" |
      jq -r --arg ACTION "CREATE" \
            --arg CLUSTER_NAME "$cluster_name" \
            --arg VM_NAME "${control_plane_hostnames[$node]}" \
            --arg CLUSTER_DOMAIN "${cluster_domain}" \
            --arg IP_ADDRESS "${control_plane_ip_addresses[$node]}" \
            '.Action = $ACTION |
             .ResourceRecordSet.Name = $CLUSTER_NAME+"-"+$VM_NAME+"."+$CLUSTER_DOMAIN+"." |
             .ResourceRecordSet.ResourceRecords[0].Value = $IP_ADDRESS')
    ROUTE53_CREATE_JSON=$(echo "${ROUTE53_CREATE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
    node_record=$(echo "${node_record}" |
      jq -r --arg ACTION "DELETE" '.Action = $ACTION')
    ROUTE53_DELETE_JSON=$(echo "${ROUTE53_DELETE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
  done
  for (( node=0; node < 3; node++)); do
    echo "Creating DNS entry for ${compute_hostnames[$node]}"
    node_record=$(echo "${DNS_RECORD}" |
      jq -r --arg ACTION "CREATE" \
            --arg CLUSTER_NAME "$cluster_name" \
            --arg VM_NAME "${compute_hostnames[$node]}" \
            --arg CLUSTER_DOMAIN "${cluster_domain}" \
            --arg IP_ADDRESS "${compute_ip_addresses[$node]}" \
            '.Action = $ACTION |
             .ResourceRecordSet.Name = $CLUSTER_NAME+"-"+$VM_NAME+"."+$CLUSTER_DOMAIN+"." |
             .ResourceRecordSet.ResourceRecords[0].Value = $IP_ADDRESS')
    ROUTE53_CREATE_JSON=$(echo "${ROUTE53_CREATE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
    node_record=$(echo "${node_record}" |
      jq -r --arg ACTION "DELETE" '.Action = $ACTION')
    ROUTE53_DELETE_JSON=$(echo "${ROUTE53_DELETE_JSON}" | jq --argjson DNS_RECORD "$node_record" -r '.Changes[.Changes|length] |= .+ $DNS_RECORD')
  done

  echo "Creating json to create Node DNS records..."
  echo ${ROUTE53_CREATE_JSON} > "${SHARED_DIR}"/dns-nodes-create.json

  echo "Creating json file to delete Node DNS records..."
  echo ${ROUTE53_DELETE_JSON} > "${SHARED_DIR}"/dns-nodes-delete.json
fi

echo "$(date -u --rfc-3339=seconds) - Create terraform.tfvars ..."
cat >"${SHARED_DIR}/terraform.tfvars" <<-EOF
machine_cidr = "${machine_cidr}"
vm_template = "${vm_template}"
vsphere_cluster = "${vsphere_cluster}"
vsphere_datacenter = "${vsphere_datacenter}"
vsphere_datastore = "${vsphere_datastore}"
vsphere_server = "${vsphere_url}"
ipam = "ipam.vmc.ci.openshift.org"
cluster_id = "${cluster_name}"
base_domain = "${base_domain}"
cluster_domain = "${cluster_domain}"
ssh_public_key_path = "${ssh_pub_key_path}"
compute_memory = "16384"
compute_num_cpus = "4"
vm_network = "${vsphere_portgroup}"
vm_dns_addresses = ["${dns_server}"]

bootstrap_ip_address = "${bootstrap_ip_address}"
lb_ip_address = "${lb_ip_address}"
compute_ip_addresses = ${compute_ip_addresses}
control_plane_ip_addresses = ${control_plane_ip_addresses}
EOF

echo "$(date -u --rfc-3339=seconds) - Create variables.ps1 ..."
cat >"${SHARED_DIR}/variables.ps1" <<-EOF
\$clustername = "${cluster_name}"
\$basedomain = "${base_domain}"
\$clusterdomain = "${cluster_domain}"
\$sshkeypath = "${ssh_pub_key_path}"

\$machine_cidr = "${machine_cidr}"

\$vm_template = "${vm_template}"
\$vcenter = "${vsphere_url}"
\$portgroup = "${vsphere_portgroup}"
\$datastore = "${vsphere_datastore}"
\$datacenter = "${vsphere_datacenter}"
\$cluster = "${vsphere_cluster}"
\$vcentercredpath = "secrets/vcenter-creds.xml"

\$ipam = "ipam.vmc.ci.openshift.org"

\$dns = "${dns_server}"
\$gateway = "${gateway}"
\$netmask ="${netmask}"

\$bootstrap_ip_address = "${bootstrap_ip_address}"
\$lb_ip_address = "${lb_ip_address}"

\$control_plane_memory = 16384
\$control_plane_num_cpus = 4
\$control_plane_count = 3
\$control_plane_ip_addresses = $(echo ${control_plane_ip_addresses} | tr -d [])
\$control_plane_hostnames = $(printf "\"%s\"," "${control_plane_hostnames[@]}" | sed 's/,$//')

\$compute_memory = 16384
\$compute_num_cpus = 4
\$compute_count = 3
\$compute_ip_addresses = $(echo ${compute_ip_addresses} | tr -d [])
\$compute_hostnames = $(printf "\"%s\"," "${compute_hostnames[@]}" | sed 's/,$//')
EOF

echo "$(date -u --rfc-3339=seconds) - Create secrets.auto.tfvars..."
cat >"${SHARED_DIR}/secrets.auto.tfvars" <<-EOF
vsphere_password="${GOVC_PASSWORD}"
vsphere_user="${GOVC_USERNAME}"
ipam_token=""
EOF

if command -v pwsh &> /dev/null
then
  echo "Creating powercli credentials file"
  pwsh -command "\$User='${GOVC_USERNAME}';\$Password=ConvertTo-SecureString -String '${GOVC_PASSWORD}' -AsPlainText -Force;\$Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList \$User, \$Password;\$Credential | Export-Clixml ${SHARED_DIR}/vcenter-creds.xml"
fi

dir=/tmp/installer
mkdir "${dir}/"
pushd ${dir}
cp -t "${dir}" \
  "${SHARED_DIR}/install-config.yaml"

echo "$(date +%s)" >"${SHARED_DIR}/TEST_TIME_INSTALL_START"

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

# remove channel from CVO
sed -i '/^  channel:/d' "manifests/cvo-overrides.yaml"

### Remove control plane machines
echo "Removing control plane machines..."
rm -f openshift/99_openshift-cluster-api_master-machines-*.yaml

### Remove compute machinesets (optional)
echo "Removing compute machinesets..."
rm -f openshift/99_openshift-cluster-api_worker-machineset-*.yaml

if [[ ${PATCH_INFRA_MANIFEST:-} == "true" ]]; then
  ### Update platform spec in the infra resource
  echo "Patching infrastructure resource manifest with the 'External' platform type..."
  cat <<EOF >/tmp/infraPlatformSpecPatch.yml
spec:
  platformSpec:
    type: External
    external:
      platformName: vSphere
status:
  platform: External
  platformStatus:
      type: External
      external: {}
EOF
  yq-go m -x -i "manifests/cluster-infrastructure-02-config.yml" "/tmp/infraPlatformSpecPatch.yml"

else

  echo "Adding vSphere cloud controller manager manifests..."
  cat >"manifests/99_vsphere_cloud_controller_manager_namespace.yaml" <<-EOF
---
apiVersion: v1
kind: Namespace
metadata:
  labels:
    kubernetes.io/metadata.name: vsphere-cloud-controller-manager
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/enforce-version: v1.24
    pod-security.kubernetes.io/warn: privileged
    security.openshift.io/scc.podSecurityLabelSync: "false"
  name: vsphere-cloud-controller-manager
spec:
  finalizers:
  - kubernetes
EOF
  cat >"manifests/99_vsphere_cloud_controller_manager_sa.yaml" <<-EOF
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cloud-controller-manager
  labels:
    vsphere-cpi-infra: service-account
    component: cloud-controller-manager
  namespace: vsphere-cloud-controller-manager
EOF
  cat >"manifests/99_vsphere_cloud_controller_manager_secret.yaml" <<-EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: vsphere-cloud-secret
  labels:
    vsphere-cpi-infra: secret
    component: cloud-controller-manager
  namespace: vsphere-cloud-controller-manager
  # NOTE: this is just an example configuration, update with real values based on your environment
stringData:
  ${vsphere_url}.username: "${GOVC_USERNAME}"
  ${vsphere_url}.password: "${GOVC_PASSWORD}"
EOF
  cat >"manifests/99_vsphere_cloud_controller_manager_cm.yaml" <<-EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: vsphere-cloud-config
  labels:
    vsphere-cpi-infra: config
    component: cloud-controller-manager
  namespace: vsphere-cloud-controller-manager
data:
  # NOTE: this is just an example configuration, update with real values based on your environment
  vsphere.conf: |
    # Global properties in this section will be used for all specified vCenters unless overriden in VirtualCenter section.
    global:
      port: 443
      # set insecureFlag to true if the vCenter uses a self-signed cert
      insecureFlag: true
      # settings for using k8s secret
      secretName: vsphere-cloud-secret
      secretNamespace: vsphere-cloud-controller-manager

    # vcenter section
    vcenter:
      ${vsphere_url}:
        server: ${vsphere_url}
        datacenters:
          - ${vsphere_datacenter}
    # labels for regions and zones
    #labels:
    #  region: k8s-region
    #  zone: k8s-zone
EOF
  cat >"manifests/99_vsphere_cloud_controller_manager_rolebinding.yaml" <<-EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: servicecatalog.k8s.io:apiserver-authentication-reader
  labels:
    vsphere-cpi-infra: role-binding
    component: cloud-controller-manager
  namespace: kube-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: extension-apiserver-authentication-reader
subjects:
  - apiGroup: ""
    kind: ServiceAccount
    name: cloud-controller-manager
    namespace: vsphere-cloud-controller-manager
  - apiGroup: ""
    kind: User
    name: cloud-controller-manager
EOF
  cat >"manifests/99_vsphere_cloud_controller_manager_clusterrolebinding.yaml" <<-EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:cloud-controller-manager
  labels:
    vsphere-cpi-infra: cluster-role-binding
    component: cloud-controller-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:cloud-controller-manager
subjects:
  - kind: ServiceAccount
    name: cloud-controller-manager
    namespace: vsphere-cloud-controller-manager
  - kind: User
    name: cloud-controller-manager
EOF
  cat >"manifests/99_vsphere_cloud_controller_manager_clusterrole.yaml" <<-EOF
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:cloud-controller-manager
  labels:
    vsphere-cpi-infra: role
    component: cloud-controller-manager
rules:
  - apiGroups:
      - ""
    resources:
      - events
    verbs:
      - create
      - patch
      - update
  - apiGroups:
      - ""
    resources:
      - nodes
    verbs:
      - "*"
  - apiGroups:
      - ""
    resources:
      - nodes/status
    verbs:
      - patch
  - apiGroups:
      - ""
    resources:
      - services
    verbs:
      - list
      - patch
      - update
      - watch
  - apiGroups:
      - ""
    resources:
      - services/status
    verbs:
      - patch
  - apiGroups:
      - ""
    resources:
      - serviceaccounts
    verbs:
      - create
      - get
      - list
      - watch
      - update
  - apiGroups:
      - ""
    resources:
      - persistentvolumes
    verbs:
      - get
      - list
      - update
      - watch
  - apiGroups:
      - ""
    resources:
      - endpoints
    verbs:
      - create
      - get
      - list
      - watch
      - update
  - apiGroups:
      - ""
    resources:
      - secrets
    verbs:
      - get
      - list
      - watch
  - apiGroups:
      - "coordination.k8s.io"
    resources:
      - leases
    verbs:
      - create
      - get
      - list
      - watch
      - update
  - apiGroups:
    - security.openshift.io
    resourceNames:
    - privileged
    resources:
    - securitycontextconstraints
    verbs:
    - use
EOF
  cat >"manifests/99_vsphere_cloud_controller_manager_ds.yaml" <<-EOF
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: vsphere-cloud-controller-manager
  labels:
    component: cloud-controller-manager
    tier: control-plane
  namespace: vsphere-cloud-controller-manager
spec:
  selector:
    matchLabels:
      name: vsphere-cloud-controller-manager
  updateStrategy:
    type: RollingUpdate
  template:
    metadata:
      labels:
        name: vsphere-cloud-controller-manager
        component: cloud-controller-manager
        tier: control-plane
    spec:
      tolerations:
        - key: node.cloudprovider.kubernetes.io/uninitialized
          value: "true"
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          effect: NoSchedule
          operator: Exists
        - key: node-role.kubernetes.io/control-plane
          effect: NoSchedule
          operator: Exists
        - key: node.kubernetes.io/not-ready
          effect: NoSchedule
          operator: Exists
      securityContext:
        runAsUser: 1001
      serviceAccountName: cloud-controller-manager
      priorityClassName: system-node-critical
      containers:
        - name: vsphere-cloud-controller-manager
          image: gcr.io/cloud-provider-vsphere/cpi/release/manager:v1.27.0
          env:
          - name: "KUBERNETES_SERVICE_HOST"
            value: "api-int.${cluster_domain}"
          - name: "KUBERNETES_SERVICE_PORT"
            value: "6443"
          args:
            - --cloud-provider=vsphere
            - --v=2
            - --cloud-config=/etc/cloud/vsphere.conf
          volumeMounts:
            - mountPath: /etc/cloud
              name: vsphere-config-volume
              readOnly: true
          resources:
            requests:
              cpu: 200m
      hostNetwork: true
      volumes:
        - name: vsphere-config-volume
          configMap:
            name: vsphere-cloud-config
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/control-plane
                operator: Exists
            - matchExpressions:
              - key: node-role.kubernetes.io/master
                operator: Exists
EOF
fi

### Make control-plane nodes unschedulable
echo "Making control-plane nodes unschedulable..."
sed -i "s;mastersSchedulable: true;mastersSchedulable: false;g" manifests/cluster-scheduler-02-config.yml

### Check hybrid network manifest
if test -f "${SHARED_DIR}/manifest_cluster-network-03-config.yml"; then
  echo "Applying hybrid network manifest..."
  cp "${SHARED_DIR}/manifest_cluster-network-03-config.yml" manifests/cluster-network-03-config.yml
fi

### Create Ignition configs
echo "Creating Ignition configs..."
openshift-install --dir="${dir}" create ignition-configs &

set +e
wait "$!"
ret="$?"
set -e

echo "$(date +%s)" >"${SHARED_DIR}/TEST_TIME_INSTALL_END"

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
