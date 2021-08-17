#!/usr/bin/env bash

set -Eeuo pipefail

declare -A external_network=(
	['openstack-kuryr']='external'
	['openstack-vexxhost']='public'
	['openstack-vh-mecha-central']='external'
	['openstack-vh-mecha-az0']='external'
	['openstack']='external'
	)

declare -A compute_flavor=(
	['openstack-kuryr']='m1.xlarge'
	['openstack-vexxhost']='ci.m1.xlarge'
	['openstack-vh-mecha-central']='m1.xlarge'
	['openstack-vh-mecha-az0']='m1.xlarge'
	['openstack']='m1.s2.xlarge'
	)

declare -A compute_azs=(
	['openstack-kuryr']=''
	['openstack-vexxhost']=''
	['openstack-vh-mecha-central']=''
	['openstack-vh-mecha-az0']='az0'
	['openstack']=''
	)

if [[ -z "${OPENSTACK_EXTERNAL_NETWORK:-}" ]]; then
	if [[ -z "${CLUSTER_TYPE:-}" ]]; then
		echo 'Set CLUSTER_TYPE or OPENSTACK_EXTERNAL_NETWORK'
		exit 1
	fi

	if ! [[ -v external_network[$CLUSTER_TYPE] ]]; then
		echo "OPENSTACK_EXTERNAL_NETWORK value for CLUSTER_TYPE '$CLUSTER_TYPE' not known."
		exit 1
	fi

	OPENSTACK_EXTERNAL_NETWORK="${external_network[$CLUSTER_TYPE]}"
fi

if [[ -z "${OPENSTACK_COMPUTE_FLAVOR:-}" ]]; then
	if [[ -z "${CLUSTER_TYPE:-}" ]]; then
		echo 'Set CLUSTER_TYPE or OPENSTACK_COMPUTE_FLAVOR'
		exit 1
	fi

	if ! [[ -v compute_flavor[$CLUSTER_TYPE] ]]; then
		echo "OPENSTACK_COMPUTE_FLAVOR value for CLUSTER_TYPE '$CLUSTER_TYPE' not known."
		exit 1
	fi

	OPENSTACK_COMPUTE_FLAVOR="${compute_flavor[$CLUSTER_TYPE]}"
fi

if [[ -z "${ZONES:-}" ]]; then
	if [[ -z "${CLUSTER_TYPE:-}" ]]; then
		echo 'Set CLUSTER_TYPE or ZONES'
		exit 1
	fi

	if ! [[ -v compute_azs[$CLUSTER_TYPE] ]]; then
		echo "ZONES value for CLUSTER_TYPE '$CLUSTER_TYPE' not known."
		exit 1
	fi

	ZONES="${compute_azs[$CLUSTER_TYPE]}"
fi

cat <<< "$OPENSTACK_EXTERNAL_NETWORK" > "${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK"
cat <<< "$OPENSTACK_COMPUTE_FLAVOR"   > "${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR"
cat <<< "$ZONES"                      > "${SHARED_DIR}/ZONES"


# We have to truncate cluster name to 14 chars, because there is a limitation in the install-config
# Now it looks like "ci-op-rl6z646h-65230".
# We will remove "ci-op-" prefix from there to keep just last 14 characters. and it cannot start with a "-"
UNSAFE_CLUSTER_NAME="${NAMESPACE}-${JOB_NAME_HASH}"
cat <<< "${UNSAFE_CLUSTER_NAME#"ci-op-"}" > "${SHARED_DIR}/CLUSTER_NAME"

cat <<EOF
CLUSTER_TYPE: $CLUSTER_TYPE
OPENSTACK_EXTERNAL_NETWORK: $OPENSTACK_EXTERNAL_NETWORK
OPENSTACK_COMPUTE_FLAVOR: $OPENSTACK_COMPUTE_FLAVOR
CLUSTER_NAME: "${UNSAFE_CLUSTER_NAME#"ci-op-"}"
ZONES: $ZONES
EOF
