#!/bin/bash
#
# Download and copy the kata containers RPM to /host/var/local/kata-containers.rpm
# on each worker node. The RPM is going to be installed by the test automation code.

# By default it's going to skip the rpm installation
[[ "${INSTALL_KATA_RPM}" != "true" ]] && exit 0

cd /tmp || exit 1

# Read from secrets
KATA_RPM_BASE_URL=$(cat /usr/local/sandboxed-containers-operator-ci-secrets/secrets/KATA_RPM_BASE_URL)

arch=$(uname -m)
ver=$(echo "$KATA_RPM_VERSION" | cut -d- -f1)
build=$(echo "$KATA_RPM_VERSION" | cut -d- -f2)
brew_auth="$(oc get -n openshift-config secret/pull-secret -ojson  | jq -r '.data.".dockerconfigjson"' |  base64 -d | jq -r '.auths."registry.redhat.io".auth' | base64 -d)"

KATA_RPM_BUILD_URL="${KATA_RPM_BASE_URL}/${ver}/${build}/${arch}/kata-containers-${KATA_RPM_VERSION}.${arch}.rpm"

md5sum_file="${KATA_RPM_BUILD_MD5SUM}  kata-containers.rpm"
curl -L -k -o kata-containers.rpm -u "${brew_auth}" "${KATA_RPM_BUILD_URL}"
echo "${md5sum_file}" | md5sum -c -

nodes=$(oc get node -l node-role.kubernetes.io/worker= -o name)
for node in $nodes;do
    dd if=kata-containers.rpm| oc debug -n default -T "${node}" -- dd of=/host/var/local/kata-containers.rpm
    oc debug -n default -T "${node}" -- bash -c "echo ${md5sum_file} > /host/var/local/kata-containers.rpm.md5sum"
done