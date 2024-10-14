#!/bin/bash
set -xeuo pipefail

# Note: Cannot source '${SHARED_DIR}/ci-functions.sh' from this script
# because it is run before the AWS EC2 steps.

# TODO:
# - Handle MICROSHIFT_GIT=PR_URL

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

allowed_os=(
	"rhel-9.2"
	"rhel-9.3"
	"rhel-9.4"
)

# shellcheck disable=SC2153  # possible misspelling
if [[ " ${allowed_os[*]} " =~ [[:space:]]${MICROSHIFT_OS}[[:space:]] ]]; then
	: ok
else
	echo "MICROSHIFT_OS must have value one of: ${allowed_os[*]}"
	exit 1
fi

if [[ "${MICROSHIFT_ARCH}" != "x86_64" ]] && [[ "${MICROSHIFT_ARCH}" != "arm64" ]]; then
	echo "MICROSHIFT_ARCH must have value: x86_64 or arm64"
	exit 1
fi

: Getting OCP version from release image
oc registry login -a /tmp/registry.json
OCP_VERSION=$(oc adm release info -o=jsonpath='{.metadata.version}' -a /tmp/registry.json "${RELEASE_IMAGE_LATEST}" | cut -d. -f1-2)
rm -f /tmp/registry.json

if [[ -z "${EC2_INSTANCE_TYPE+x}" ]] || [[ "${EC2_INSTANCE_TYPE}" == "" ]]; then
	: EC2_INSTANCE_TYPE is empty, determining from ARCH
	EC2_INSTANCE_TYPE="${instance_types[${MICROSHIFT_ARCH}]}"
fi

if [ -n "${MICROSHIFT_PR}" ] && [ -n "${MICROSHIFT_GIT}" ]; then
	>&2 echo "Only MICROSHIFT_PR or MICROSHIFT_GIT can be provided"
	exit 1
fi

MICROSHIFT_CLUSTERBOT_SETTINGS="${SHARED_DIR}/microshift-clusterbot-settings"
cat <<EOF >"${MICROSHIFT_CLUSTERBOT_SETTINGS}"
MICROSHIFT_OS=${MICROSHIFT_OS}
ARCH=${MICROSHIFT_ARCH}
MICROSHIFT_GIT=${MICROSHIFT_GIT}
MICROSHIFT_PR=${MICROSHIFT_PR}
EC2_INSTANCE_TYPE=${EC2_INSTANCE_TYPE}
OCP_VERSION=${OCP_VERSION}
EOF

cat "${MICROSHIFT_CLUSTERBOT_SETTINGS}"
