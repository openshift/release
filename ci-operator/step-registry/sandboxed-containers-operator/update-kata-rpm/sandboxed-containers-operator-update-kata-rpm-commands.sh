#!/bin/bash
#
# Download, copy and install the kata-containers RPM on each worker node.

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

echo "Downloaded RPM: $(ls -lh kata-containers.rpm)"

# checks for a bad URL
if grep -q 'title.*404 Not Found' kata-containers.rpm && \
    grep -q 'p.*The requested URL was not found' kata-containers.rpm ; then
    echo "ERROR: curl couldn't find ${kata_rpm_build_url}"
    echo -e "kata-containers.rpm content:\n$(head -20 kata-containers.rpm)"
    exit 3
fi

target_version=$(rpm -qp ./kata-containers.rpm)
kata_rpm_md5sum=$(md5sum kata-containers.rpm | cut -d' ' -f1)
echo "Target RPM: ${target_version}"
echo "RPM md5sum: ${kata_rpm_md5sum}"

nodes=$(oc get node -l node-role.kubernetes.io/worker= -o name)
if [[ -z "${nodes}" ]]; then
	echo "ERROR: workers not found"
	exit 1
fi

skipped=0
updated=0
failed_nodes=""

for node in $nodes;do
    # Check installed version on this node
    installed=""
    installed=$(oc debug -n default "${node}" -- chroot /host rpm -q kata-containers 2>/dev/null) || true

    if [ "${installed}" = "${target_version}" ]; then
        echo "${node}: ${target_version} already installed, skipping"
        skipped=$((skipped + 1))
        continue
    fi

    echo "${node}: installed=${installed:-none}, upgrading to ${target_version}"

    # Copy the RPM to the node
    dd if=kata-containers.rpm | oc debug -n default -T "${node}" -- dd of=/host/var/local/kata-containers.rpm

    # Verify checksum
    node_md5=$(oc debug -n default "${node}" -- bash -c "md5sum /host/var/local/kata-containers.rpm | cut -d' ' -f1")
    if [ "${node_md5}" != "${kata_rpm_md5sum}" ]; then
        echo "ERROR: checksum mismatch on ${node}: expected ${kata_rpm_md5sum}, got ${node_md5}"
        failed_nodes="${node} ${failed_nodes}"
        continue
    fi

    # Install the RPM
    install_output=""
    install_err=0
    install_output=$(oc debug -n default "${node}" -- chroot /host bash -c \
        "ostree admin unlock --hotfix && rpm -Uvh /var/local/kata-containers.rpm && rpm -q kata-containers && systemctl restart crio" 2>&1) || install_err=$?

    if [ $install_err -ne 0 ]; then
        echo "ERROR: install failed on ${node} (exit ${install_err}): ${install_output}"
        failed_nodes="${node} ${failed_nodes}"
        continue
    fi

    echo "${node}: installed successfully"
    updated=$((updated + 1))
done

if [ -n "${failed_nodes}" ]; then
    echo "ERROR: failed on nodes: ${failed_nodes}"
    exit 4
fi

echo "Done: ${updated} node(s) updated, ${skipped} node(s) already up-to-date"
