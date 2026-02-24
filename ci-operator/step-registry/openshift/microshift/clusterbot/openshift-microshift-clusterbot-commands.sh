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
	"rhel-9.6"
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

if [ -n "${MICROSHIFT_NIGHTLY:-}" ] && { [ -n "${MICROSHIFT_PR}" ] || [ -n "${MICROSHIFT_GIT}" ]; }; then
	>&2 echo "MICROSHIFT_NIGHTLY cannot be used with MICROSHIFT_PR or MICROSHIFT_GIT"
	exit 1
fi

# If MICROSHIFT_NIGHTLY is set, download nightly RPMs from S3 cache
if [[ -n "${MICROSHIFT_NIGHTLY:-}" ]]; then
	: Downloading nightly RPMs from S3 build cache

	# S3 bucket configuration (same bucket used by MicroShift CI cache)
	AWS_BUCKET_NAME="microshift-build-cache-us-west-2"

	# Map architecture names (arm64 -> aarch64 for S3 cache structure)
	S3_ARCH="${MICROSHIFT_ARCH}"
	[[ "${MICROSHIFT_ARCH}" == "arm64" ]] && S3_ARCH="aarch64"

	# Install AWS CLI
	if ! command -v aws &>/dev/null; then
		curl -s "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscliv2.zip
		unzip -q /tmp/awscliv2.zip -d /tmp
		/tmp/aws/install --install-dir /tmp/awscli --bin-dir /tmp/bin
		rm -rf /tmp/awscliv2.zip /tmp/aws
	fi
	AWSCLI="${AWSCLI:-/tmp/bin/aws}"

	# Configure AWS credentials
	mkdir -p ~/.aws
	chmod 0700 ~/.aws

	# Disable tracing for credential handling
	set +x
	cat > ~/.aws/credentials <<CREDS
[microshift-ci]
aws_access_key_id = $(cat /var/run/microshift-dev-access-keys/aws_access_key_id)
aws_secret_access_key = $(cat /var/run/microshift-dev-access-keys/aws_secret_access_key)
CREDS
	set -x

	chmod -R go-rwx ~/.aws
	export AWS_PROFILE=microshift-ci

	# Get the latest cache tag for this branch that has nightly RPMs
	CACHE_BRANCH="release-${OCP_VERSION}"
	S3_BASE="s3://${AWS_BUCKET_NAME}/${CACHE_BRANCH}/${S3_ARCH}"

	echo "Searching for nightly RPMs in ${S3_BASE}/"

	# List all tags (directories) and find one with brew-rpms.tar (nightly RPM archive)
	# Tags are typically date-based (YYMMDD format), so sort in reverse to get newest first
	AVAILABLE_TAGS=$("${AWSCLI}" s3 ls "${S3_BASE}/" | awk '/PRE/ {gsub("/",""); print $2}' | sort -rn)
	NIGHTLY_FOUND=false
	CACHE_TAG=""

	for tag in ${AVAILABLE_TAGS}; do
		echo "Checking tag: ${tag}"
		if "${AWSCLI}" s3 ls "${S3_BASE}/${tag}/brew-rpms.tar" &>/dev/null; then
			echo "Found nightly RPMs in tag: ${tag}"
			NIGHTLY_FOUND=true
			CACHE_TAG="${tag}"
			break
		fi
	done

	if [[ "${NIGHTLY_FOUND}" != "true" ]]; then
		>&2 echo "ERROR: No nightly RPMs found in any cache tag for ${CACHE_BRANCH}/${S3_ARCH}"
		exit 1
	fi

	# Save S3 path info for the prepare-host step to download directly on EC2
	# (brew-rpms.tar is too large for SHARED_DIR which is backed by k8s secrets)
	NIGHTLY_S3_PATH="${S3_BASE}/${CACHE_TAG}/brew-rpms.tar"
	echo "Using cache tag: ${CACHE_TAG}"
	echo "Nightly RPMs S3 path: ${NIGHTLY_S3_PATH}"
	echo "${NIGHTLY_S3_PATH}" > "${SHARED_DIR}/brew-rpms-s3-path"

	# Copy AWS credentials to SHARED_DIR for the prepare-host step
	cp /var/run/microshift-dev-access-keys/aws_access_key_id "${SHARED_DIR}/aws_access_key_id"
	cp /var/run/microshift-dev-access-keys/aws_secret_access_key "${SHARED_DIR}/aws_secret_access_key"
fi

MICROSHIFT_CLUSTERBOT_SETTINGS="${SHARED_DIR}/microshift-clusterbot-settings"
cat <<EOF >"${MICROSHIFT_CLUSTERBOT_SETTINGS}"
MICROSHIFT_OS=${MICROSHIFT_OS}
ARCH=${MICROSHIFT_ARCH}
MICROSHIFT_GIT=${MICROSHIFT_GIT}
MICROSHIFT_PR=${MICROSHIFT_PR}
MICROSHIFT_NIGHTLY=${MICROSHIFT_NIGHTLY:-}
EC2_INSTANCE_TYPE=${EC2_INSTANCE_TYPE}
OCP_VERSION=${OCP_VERSION}
EOF

cat "${MICROSHIFT_CLUSTERBOT_SETTINGS}"
