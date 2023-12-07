#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

CLUSTER_NAME="$(<"${SHARED_DIR}/CLUSTER_NAME")"
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"
OPENSTACK_CONTROLPLANE_FLAVOR="${OPENSTACK_CONTROLPLANE_FLAVOR:-$(<"${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR")}"
OPENSTACK_COMPUTE_FLAVOR="${OPENSTACK_COMPUTE_FLAVOR:-$(<"${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR")}"
ZONES="${ZONES:-$(<"${SHARED_DIR}/ZONES")}"
WORKER_REPLICAS="${WORKER_REPLICAS:-3}"

API_IP=$(<"${SHARED_DIR}/API_IP")
INGRESS_IP=$(<"${SHARED_DIR}/INGRESS_IP")

PULL_SECRET=$(<"${CLUSTER_PROFILE_DIR}/pull-secret")
SSH_PUB_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")

IFS=' ' read -ra ZONES <<< "$ZONES"
ZONES_COUNT=${#ZONES[@]}
ZONES_JSON="$(echo -n "${ZONES[@]:0:${ZONES_COUNT}}" | jq -cRs '(. / " ")')"
echo "OpenStack Availability Zones: '${ZONES_JSON}'"

INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"

cat > "$INSTALL_CONFIG" <<EOF
apiVersion: v1
baseDomain: '${BASE_DOMAIN}'
metadata:
  name: '${CLUSTER_NAME}'
compute:
- name: worker
  replicas: ${WORKER_REPLICAS}
  platform:
    openstack:
      type: '${OPENSTACK_COMPUTE_FLAVOR}'
controlPlane:
  name: master
  replicas: 3
  platform:
    openstack:
      type: '${OPENSTACK_CONTROLPLANE_FLAVOR}'
networking:
  networkType: '${NETWORK_TYPE}'
platform:
  openstack:
    cloud: '${OS_CLOUD}'
pullSecret: >-
  ${PULL_SECRET}
sshKey: |-
  ${SSH_PUB_KEY}
EOF

case "$CONFIG_TYPE" in
	minimal)
		yq --yaml-output --in-place ".
			| .platform.openstack.externalDNS = [\"1.1.1.1\", \"1.0.0.1\"]
			| .platform.openstack.externalNetwork = \"${OPENSTACK_EXTERNAL_NETWORK}\"
			| .platform.openstack.ingressFloatingIP = \"${INGRESS_IP}\"
			| .platform.openstack.apiFloatingIP = \"${API_IP}\"
		" "$INSTALL_CONFIG"
		;;
	proxy*)
		yq --yaml-output --in-place ".
			| .networking.machineNetwork[0].cidr = \"$(<"${SHARED_DIR}"/MACHINES_SUBNET_RANGE)\"
			| .platform.openstack.apiVIP = \"${API_IP}\"
			| .platform.openstack.ingressVIP = \"${INGRESS_IP}\"
			| .platform.openstack.machinesSubnet = \"$(<"${SHARED_DIR}"/MACHINES_SUBNET_ID)\"
		" "$INSTALL_CONFIG"

		if [[ -f "${SHARED_DIR}/PROXY_INTERFACE" ]]; then
			PROXY_INTERFACE=$(<"${SHARED_DIR}/PROXY_INTERFACE")
			SQUID_AUTH=$(<"${SHARED_DIR}/SQUID_AUTH")
			yq --yaml-output --in-place ".
				| .proxy.httpProxy  = \"http://${SQUID_AUTH}@${PROXY_INTERFACE}:3128/\"
				| .proxy.httpsProxy = \"https://${SQUID_AUTH}@${PROXY_INTERFACE}:3130/\"
				| .additionalTrustBundle = \"$(<"${SHARED_DIR}/domain.crt")\"
			" "$INSTALL_CONFIG"
		fi

		if [[ -f "${SHARED_DIR}/LB_HOST" ]]; then
    			yq --yaml-output --in-place ".
    			    | .platform.openstack.loadBalancer.type = \"UserManaged\"
    			" "$INSTALL_CONFIG"
		fi
		;;
	dualstack*)
		source "${SHARED_DIR}/VIPS"
		API_VIPS=$(echo -n "${API_VIPS[@]}" | jq -cRs '(. / " ")')
		INGRESS_VIPS=$(echo -n "${INGRESS_VIPS[@]}" | jq -cRs '(. / " ")')
		yq --yaml-output --in-place ".
			| .networking.machineNetwork[0].cidr = \"${MACHINES_SUBNET_v4_RANGE:?}\"
			| .networking.machineNetwork[1].cidr = \"${MACHINES_SUBNET_v6_RANGE:?}\"
			| .networking.clusterNetwork[0].cidr = \"10.128.0.0/14\"
			| .networking.clusterNetwork[0].hostPrefix = 23
			| .networking.clusterNetwork[1].cidr = \"fd01::/48\"
			| .networking.clusterNetwork[1].hostPrefix = 64
			| .networking.serviceNetwork = [\"172.30.0.0/16\", \"fd02::/112\"]
			| .platform.openstack.apiVIPs = $API_VIPS
			| .platform.openstack.ingressVIPs = $INGRESS_VIPS
			| .platform.openstack.controlPlanePort.fixedIPs[0].subnet.name = \"${CONTROL_PLANE_SUBNET_V4}\"
			| .platform.openstack.controlPlanePort.fixedIPs[1].subnet.name = \"${CONTROL_PLANE_SUBNET_V6}\"
			| .platform.openstack.controlPlanePort.network.name = \"${CONTROL_PLANE_NETWORK}\"
			| .platform.openstack.controlPlanePort.network.name = \"${CONTROL_PLANE_NETWORK}\"
			| .platform.openstack.controlPlanePort.network.name = \"${CONTROL_PLANE_NETWORK}\"
		" "$INSTALL_CONFIG"

		if [[ "${CONFIG_TYPE}" == "dualstack-v6primary" ]]; then
			yq --yaml-output --in-place ".
				| .platform.openstack.apiVIPs = (.platform.openstack.apiVIPs | reverse)
				| .platform.openstack.ingressVIPs = (.platform.openstack.ingressVIPs | reverse)
				| .networking.machineNetwork = (.networking.machineNetwork | reverse)
				| .networking.clusterNetwork = (.networking.clusterNetwork | reverse)
				| .networking.serviceNetwork = (.networking.serviceNetwork | reverse)
			" "$INSTALL_CONFIG"
		fi
		;;
	*)
		echo "No valid install config type specified. Please check CONFIG_TYPE"
		exit 1
		;;
esac

if [[ "${ZONES_COUNT}" -gt '0' ]]; then
	yq --yaml-output --in-place ".
		| .controlPlane.platform.openstack.zones = ${ZONES_JSON}
		| .controlPlane.platform.openstack.rootVolume.type = \"tripleo\"
		| .controlPlane.platform.openstack.rootVolume.size = 30
		| .controlPlane.platform.openstack.rootVolume.zones = ${ZONES_JSON}
		| .compute[0].platform.openstack.zones = ${ZONES_JSON}
		| .compute[0].platform.openstack.rootVolume.type = \"tripleo\"
		| .compute[0].platform.openstack.rootVolume.size = 30
		| .compute[0].platform.openstack.rootVolume.zones = ${ZONES_JSON}
	" "$INSTALL_CONFIG"
fi

if [[ ${ADDITIONAL_WORKERS_NETWORKS:-} != "" ]]; then
	declare -a networks
	for network in $ADDITIONAL_WORKERS_NETWORKS; do
		networks+=("$(openstack network show -f value -c id "${network}")")
	done

	networks_json="$(echo -n "${networks[@]}" | jq -cRs '(. / " ")')"

	yq --yaml-output --in-place ".
		| .compute[0].platform.openstack.additionalNetworkIDs = ${networks_json}
	" "$INSTALL_CONFIG"
fi

if [ "${FIPS_ENABLED:-}" = "true" ]; then
	echo "Adding 'fips: true' to install-config.yaml"
	yq --yaml-output --in-place ".
		| .fips = true
	" "$INSTALL_CONFIG"
fi

if [ -n "${FEATURE_SET}" ]; then
        echo "Adding 'featureSet: ...' to install-config.yaml"
	yq --yaml-output --in-place ".
		| .featureSet = \"${FEATURE_SET}\"
	" "$INSTALL_CONFIG"
fi

if [[ -n "${OVERRIDE_OPENSHIFT_SDN_DEPRECATION:-}" ]]; then
        # Needed for 4.15+; see ci-operator/step-registry/sdn/conf/sdn-conf-commands.sh
        cat > "${SHARED_DIR}/manifest_cluster-network-02-config.yml" << EOF
apiVersion: config.openshift.io/v1
kind: Network
metadata:
  name: cluster
spec:
  clusterNetwork:
  - cidr: 10.128.0.0/14
    hostPrefix: 23
  networkType: OpenShiftSDN
  serviceNetwork:
  - 172.30.0.0/16
EOF
        yq --yaml-output --in-place ".
		| .networking.networkType = \"OVNKubernetes\"
	" "$INSTALL_CONFIG"
fi

# Regenerate install-config.yaml to fill in unset values with default values.
# Note that this triggers some validation against the OpenStack infrastructure.
(
	declare dir=''
	dir="$(mktemp -d)"
	cp "$INSTALL_CONFIG" "${dir}/install-config.yaml"
	openshift-install --dir "$dir" create install-config
	cp "${dir}/install-config.yaml" "$INSTALL_CONFIG"
)

# Make a redacted version available for debugging in the artifacts dir.
python -c 'import yaml;
import sys
data = yaml.safe_load(open(sys.argv[1]))
data["pullSecret"] = "redacted"
if "proxy" in data:
    data["proxy"] = "redacted"
print(yaml.dump(data))
' "$INSTALL_CONFIG" > "${ARTIFACT_DIR}/install-config.yaml"
