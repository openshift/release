#!/bin/bash
#
# Download and copy the kata containers RPM to /host/var/local/kata-containers.rpm
# on each worker node. The RPM is going to be installed by the test automation code.

set -o nounset
set -o errexit
set -o pipefail

# Initialize step parameters
INSTALL_KATA_RPM="${INSTALL_KATA_RPM:-false}"
KATA_RPM_BUILD_TASK="${KATA_RPM_BUILD_TASK:-}"
KATA_RPM_VERSION="${KATA_RPM_VERSION:-}"

# By default it's going to skip the rpm installation
if [[ "${INSTALL_KATA_RPM}" != "true" ]]; then
	echo "INSTALL_KATA_RPM=${INSTALL_KATA_RPM}. Do not install the Kata RPM"
	exit 0
fi

cd /tmp || exit 1

arch=$(uname -m)
if [ -n "${KATA_RPM_BUILD_TASK}" ];then
    kata_rpm_base_task_url="https://download.devel.redhat.com/brewroot/work/tasks"
    # To the base URL it's appended the "last four digits of task ID"/"full task ID"
    kata_rpm_build_url="${kata_rpm_base_task_url}/${KATA_RPM_BUILD_TASK: -4}/${KATA_RPM_BUILD_TASK}/kata-containers-${KATA_RPM_VERSION}.${arch}.rpm"
else
    ver=$(echo "$KATA_RPM_VERSION" | cut -d- -f1)
    build=$(echo "$KATA_RPM_VERSION" | cut -d- -f2)
    kata_rpm_base_url="https://download.devel.redhat.com/brewroot/vol/rhel-9/packages/kata-containers"
    kata_rpm_build_url="${kata_rpm_base_url}/${ver}/${build}/${arch}/kata-containers-${KATA_RPM_VERSION}.${arch}.rpm"
fi

echo "Get the authentication credentials for Brew"
brew_auth=${BREW_AUTH:-"$(oc get -n openshift-config secret/pull-secret -ojson  | jq -r '.data.".dockerconfigjson"' |  base64 -d | jq -r '.auths."registry.redhat.io".auth' | base64 -d)"}

echo "Download the RPM from Brew"
err=0
output="$(curl -L -k -o kata-containers.rpm -u "${brew_auth}" "${kata_rpm_build_url}" 2>&1)" || err=$?
if [ $err -ne 0 ]; then
    echo "ERROR: curl error ${err} trying to get ${kata_rpm_build_url}"
    echo "ERROR: ${output}"
    exit 2
fi

ls -lh kata-containers.rpm

# checks for a bad URL
if grep -q 'title.*404 Not Found' kata-containers.rpm && \
    grep -q 'p.*The requested URL was not found' kata-containers.rpm ; then
    echo "ERROR: curl couldn't find ${kata_rpm_build_url}"
    echo -e "kata-containers.rpm content:\n$(head -20 kata-containers.rpm)"
    exit 3
fi

kata_rpm_md5sum=$(md5sum kata-containers.rpm | cut -d' ' -f1)

echo "Upload to workers and check against the rpm md5sum"
failed_nodes=""
nodes=$(oc get node -l node-role.kubernetes.io/worker= -o name)
if [[ -z "${nodes}" ]]; then
	echo "ERROR: workers not found"
	exit 1
fi

for node in $nodes;do
    dd if=kata-containers.rpm| oc debug -n default -T "${node}" -- dd of=/host/var/local/kata-containers.rpm
    output=$(oc debug -n default "${node}" -- bash -c "md5sum  /host/var/local/kata-containers.rpm | cut -d' ' -f1")
    if [ "${output}" != "${kata_rpm_md5sum}" ]; then
        failed_nodes="${node}:${output} ${failed_nodes}"
    fi
done

# check for failures
if [ "${failed_nodes}" != "" ]; then
    echo "calculated checksum: ${kata_rpm_md5sum}"
    echo "ERROR: uploads failed on nodes ${failed_nodes}"
    exit 4
fi
