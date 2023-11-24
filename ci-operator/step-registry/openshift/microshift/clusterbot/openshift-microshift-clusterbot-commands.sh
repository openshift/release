#!/bin/bash
set -xeuo pipefail
export PS4='+ $(date "+%T.%N") \011'

# TODO:
# - Handle MICROSHIFT_GIT=PR_URL

CURRENT_RELEASE=4.15

# | Instance Type | Arch   | vCPUs | GiB |
# |---------------|--------|-------|-----|
# | t3.large      | x86_64 | 2     | 8   |
# | t3.xlarge     | x86_64 | 4     | 16  |
# | t4g.large     | arm64  | 2     | 8   |
# | t4g.xlarge    | arm64  | 4     | 16  |
declare -A instance_types=(
	[x86_64]=t3.large
	[arm64]=t4g.large
)

# ami-0931978297f275f71   RHEL-9.2.0_HVM-20230905-x86_64-38-Hourly2-GP2
# ami-0ef50c2b2eb330511   RHEL-9.3.0_HVM-20231101-x86_64-5-Hourly2-GP2
declare -A x86_64_ami=(
	["rhel-9.2"]=ami-0931978297f275f71
	["rhel-9.3"]=ami-0ef50c2b2eb330511
)

# ami-08c7e766098f8cb4f   RHEL-9.2.0_HVM-20230905-arm64-38-Hourly2-GP2
# ami-0d863285841e3f97c   RHEL-9.3.0_HVM-20231101-arm64-5-Hourly2-GP2
declare -A arm64_ami=(
	["rhel-9.2"]=ami-08c7e766098f8cb4f
	["rhel-9.3"]=ami-0d863285841e3f97c
)

if [[ "${MICROSHIFT_OS}" != "rhel-9.2" ]] && [[ "${MICROSHIFT_OS}" != "rhel-9.3" ]]; then
	echo "MICROSHIFT_OS must have value: rhel-9.2 or rhel-9.3"
	exit 1
fi

if [[ "${MICROSHIFT_ARCH}" != "x86_64" ]] && [[ "${MICROSHIFT_ARCH}" != "arm64" ]]; then
	echo "MICROSHIFT_ARCH must have value: x86_64 or arm64"
	exit 1
fi

: Getting OCP version from release image
oc registry login -a /tmp/registry.json
OCP_VERSION=$(oc adm release info -o=jsonpath='{.metadata.version}' -a /tmp/registry.json $RELEASE_IMAGE_LATEST | cut -d. -f1-2)
rm -f /tmp/registry.json

if [[ -z "${EC2_AMI+x}" ]] || [[ "${EC2_AMI}" == "" ]]; then
	: EC2_AMI is empty, determining from OS and ARCH
	if [[ "${MICROSHIFT_ARCH}" == "x86_64" ]]; then
		EC2_AMI="${x86_64_ami[${MICROSHIFT_OS}]}"
	else
		EC2_AMI="${arm64_ami[${MICROSHIFT_OS}]}"
	fi
fi

if [[ -z "${EC2_INSTANCE_TYPE+x}" ]] || [[ "${EC2_INSTANCE_TYPE}" == "" ]]; then
	: EC2_INSTANCE_TYPE is empty, determining from ARCH
	EC2_INSTANCE_TYPE="${instance_types[${MICROSHIFT_ARCH}]}"
fi

MICROSHIFT_CLUSTERBOT_SETTINGS="${SHARED_DIR}/microshift-clusterbot-settings"
cat <<EOF >"${MICROSHIFT_CLUSTERBOT_SETTINGS}"
MICROSHIFT_OS=${MICROSHIFT_OS}
MICROSHIFT_ARCH=${MICROSHIFT_ARCH}
MICROSHIFT_GIT=${MICROSHIFT_GIT}
EC2_AMI=${EC2_AMI}
EC2_INSTANCE_TYPE=${EC2_INSTANCE_TYPE}
OCP_VERSION=${OCP_VERSION}
CURRENT_RELEASE=${CURRENT_RELEASE}
EOF

cat "${MICROSHIFT_CLUSTERBOT_SETTINGS}"
