#!/usr/bin/env bash

set -Eeuo pipefail

CLUSTER_TYPE="${CLUSTER_TYPE_OVERRIDE:-$CLUSTER_TYPE}"

declare -A external_network=(
	['openstack-vexxhost']='public'
        ['openstack-operators-vexxhost']='public'
	['openstack-vh-mecha-central']='external'
	['openstack-vh-mecha-az0']='external'
	['openstack-nfv']='intel-dpdk'
	['openstack-hwoffload']='external'
	['openstack-nerc-dev']='provider'
	)

declare -A controlplane_flavor=(
	['openstack-vexxhost']='ci.m1.xlarge'
        ['openstack-operators-vexxhost']='ci.m1.large'
	['openstack-vh-mecha-central']='m1.xlarge'
	['openstack-vh-mecha-az0']='m1.xlarge'
	['openstack-nfv']='m1.xlarge'
	['openstack-hwoffload']='m1.xlarge'
	['openstack-nerc-dev']='cpu-su.4'
	)

declare -A controlplane_flavor_alternate=(
	['openstack-vexxhost']='ci.m2.xlarge'
	['openstack-vh-mecha-central']='m1.xlarge.2'
	['openstack-vh-mecha-az0']='m1.xlarge.2'
	['openstack-nfv']='m1.xlarge.2'
	['openstack-hwoffload']='m1.xlarge.2'
	)

declare -A compute_flavor=(
	['openstack-vexxhost']='ci.m1.xlarge'
        ['openstack-operators-vexxhost']='ci.m1.large'
	['openstack-vh-mecha-central']='m1.xlarge'
	['openstack-vh-mecha-az0']='m1.xlarge'
	['openstack-nfv']='m1.xlarge.nfv'
	['openstack-hwoffload']='m1.xlarge'
	['openstack-nerc-dev']='cpu-su.4'
	)

declare -A compute_azs=(
	['openstack-vexxhost']=''
        ['openstack-operators-vexxhost']=''
	['openstack-vh-mecha-central']=''
	['openstack-vh-mecha-az0']='nova'
	['openstack-nfv']=''
	['openstack-hwoffload']=''
	['openstack-nerc-dev']='nova'
	)

declare -A bastion_flavor=(
	['openstack-vexxhost']='1vcpu_2gb'
        ['openstack-operators-vexxhost']='ci.m1.small'
	['openstack-vh-mecha-central']='m1.small'
	['openstack-vh-mecha-az0']='m1.small'
	['openstack-nfv']='m1.small'
	['openstack-hwoffload']='m1.small'
	['openstack-nerc-dev']='cpu-su.4'
	)

if [[ -z "${OPENSTACK_EXTERNAL_NETWORK:-}" ]]; then
	if [[ -z "${CLUSTER_TYPE:-}" ]]; then
		echo 'Set CLUSTER_TYPE or OPENSTACK_EXTERNAL_NETWORK'
		exit 1
	fi

	if ! [[ -v external_network["$CLUSTER_TYPE"] ]]; then
		echo "OPENSTACK_EXTERNAL_NETWORK value for CLUSTER_TYPE '$CLUSTER_TYPE' not known."
		exit 1
	fi

	OPENSTACK_EXTERNAL_NETWORK="${external_network["$CLUSTER_TYPE"]}"
fi

if [[ -z "${OPENSTACK_CONTROLPLANE_FLAVOR:-}" ]]; then
	if [[ -z "${CLUSTER_TYPE:-}" ]]; then
		echo 'Set CLUSTER_TYPE or OPENSTACK_CONTROLPLANE_FLAVOR'
		exit 1
	fi

	if ! [[ -v controlplane_flavor["$CLUSTER_TYPE"] ]]; then
		echo "OPENSTACK_CONTROLPLANE_FLAVOR value for CLUSTER_TYPE '$CLUSTER_TYPE' not known."
		exit 1
	fi

	OPENSTACK_CONTROLPLANE_FLAVOR="${controlplane_flavor["$CLUSTER_TYPE"]}"
fi

# This is optional. Failure to set results in an empty file in SHARED_DIR
if [[ -z "${OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE:-}" ]]; then
	if [[ -z "${CLUSTER_TYPE:-}" ]]; then
		echo 'Set CLUSTER_TYPE or OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE to enable testing CPMS scaling'
	elif ! [[ -v controlplane_flavor_alternate["$CLUSTER_TYPE"] ]]; then
		echo "OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE value for CLUSTER_TYPE '$CLUSTER_TYPE' not known. Set OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE to enable testing CPMS scaling"
	else
		OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE="${controlplane_flavor_alternate["$CLUSTER_TYPE"]}"
	fi
fi

if [[ -z "${OPENSTACK_COMPUTE_FLAVOR:-}" ]]; then
	if [[ -z "${CLUSTER_TYPE:-}" ]]; then
		echo 'Set CLUSTER_TYPE or OPENSTACK_COMPUTE_FLAVOR'
		exit 1
	fi

	if ! [[ -v compute_flavor["$CLUSTER_TYPE"] ]]; then
		echo "OPENSTACK_COMPUTE_FLAVOR value for CLUSTER_TYPE '$CLUSTER_TYPE' not known."
		exit 1
	fi

	OPENSTACK_COMPUTE_FLAVOR="${compute_flavor["$CLUSTER_TYPE"]}"
fi

if [[ -z "${ZONES:-}" ]]; then
	if [[ -z "${CLUSTER_TYPE:-}" ]]; then
		echo 'Set CLUSTER_TYPE or ZONES'
		exit 1
	fi

	if ! [[ -v compute_azs["$CLUSTER_TYPE"] ]]; then
		echo "ZONES value for CLUSTER_TYPE '$CLUSTER_TYPE' not known."
		exit 1
	fi

	ZONES="${compute_azs["$CLUSTER_TYPE"]}"
fi

if [[ -z "${BASTION_FLAVOR:-}" ]]; then
	if [[ -z "${CLUSTER_TYPE:-}" ]]; then
		echo 'Set CLUSTER_TYPE or BASTION_FLAVOR'
		exit 1
	fi

	if ! [[ -v bastion_flavor["$CLUSTER_TYPE"] ]]; then
		echo "BASTION_FLAVOR value for CLUSTER_TYPE '$CLUSTER_TYPE' not known."
		exit 1
	fi

	BASTION_FLAVOR="${bastion_flavor["$CLUSTER_TYPE"]}"
fi

cat <<< "$OPENSTACK_EXTERNAL_NETWORK"              > "${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK"
cat <<< "$OPENSTACK_CONTROLPLANE_FLAVOR"           > "${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR"
cat <<< "$OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE" > "${SHARED_DIR}/OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE"
cat <<< "$OPENSTACK_COMPUTE_FLAVOR"                > "${SHARED_DIR}/OPENSTACK_COMPUTE_FLAVOR"
cat <<< "$ZONES"                                   > "${SHARED_DIR}/ZONES"
cat <<< "$BASTION_FLAVOR"                          > "${SHARED_DIR}/BASTION_FLAVOR"


# We have to truncate cluster name to 14 chars, because there is a limitation in the install-config
# Now it looks like "ci-op-rl6z646h-65230".
# We will remove "ci-op-" prefix from there to keep just last 14 characters. and it cannot start with a "-"
UNSAFE_CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
cat <<< "${UNSAFE_CLUSTER_NAME/ci-??-/}" > "${SHARED_DIR}/CLUSTER_NAME"

cat <<EOF
CLUSTER_TYPE: $CLUSTER_TYPE
OPENSTACK_EXTERNAL_NETWORK: $OPENSTACK_EXTERNAL_NETWORK
OPENSTACK_CONTROLPLANE_FLAVOR: $OPENSTACK_CONTROLPLANE_FLAVOR
OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE: $OPENSTACK_CONTROLPLANE_FLAVOR_ALTERNATE
OPENSTACK_COMPUTE_FLAVOR: $OPENSTACK_COMPUTE_FLAVOR
CLUSTER_NAME: $(cat "${SHARED_DIR}/CLUSTER_NAME")
ZONES: $ZONES
BASTION_FLAVOR: $BASTION_FLAVOR
PROW_JOB_ID: $PROW_JOB_ID
EOF
