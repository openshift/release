#!/bin/bash
#
# Download and copy the kata containers RPM to /host/var/local/kata-containers.rpm
# on each worker node. The RPM is going to be installed by the test automation code.

# By default it's going to skip the rpm installation
[[ "${INSTALL_KATA_RPM}" != "true" ]] && exit 0

cd /tmp || exit 1

arch=$(uname -m)
if [ -n "${KATA_RPM_BUILD_TASK}" ];then
    KATA_RPM_BASE_TASK_URL=$(cat /usr/local/sandboxed-containers-operator-ci-secrets/secrets/KATA_RPM_BUILD_TASK_BASE_URL)
    # To the base URL it's appended the "last four digits of task ID"/"full task ID"
    KATA_RPM_BUILD_URL="${KATA_RPM_BASE_TASK_URL}/${KATA_RPM_BUILD_TASK: -4}/${KATA_RPM_BUILD_TASK}/kata-containers-${KATA_RPM_VERSION}.${arch}.rpm"
else
    ver=$(echo "$KATA_RPM_VERSION" | cut -d- -f1)
    build=$(echo "$KATA_RPM_VERSION" | cut -d- -f2)
    KATA_RPM_BASE_URL=$(cat /usr/local/sandboxed-containers-operator-ci-secrets/secrets/KATA_RPM_BASE_URL)
    KATA_RPM_BUILD_URL="${KATA_RPM_BASE_URL}/${ver}/${build}/${arch}/kata-containers-${KATA_RPM_VERSION}.${arch}.rpm"
fi

brew_auth="$(oc get -n openshift-config secret/pull-secret -ojson  | jq -r '.data.".dockerconfigjson"' |  base64 -d | jq -r '.auths."registry.redhat.io".auth' | base64 -d)"

md5sum_file="${KATA_RPM_BUILD_MD5SUM}  kata-containers.rpm"
curl -L -k -o kata-containers.rpm -u "${brew_auth}" "${KATA_RPM_BUILD_URL}"
echo "Debug:"
ls -l kata-containers.rpm || true
echo "Checking against md5sum ${KATA_RPM_BUILD_MD5SUM}"
echo "${md5sum_file}" | md5sum -c -

nodes=$(oc get node -l node-role.kubernetes.io/worker= -o name)
for node in $nodes;do
    dd if=kata-containers.rpm| oc debug -n default -T "${node}" -- dd of=/host/var/local/kata-containers.rpm
    oc debug -n default -T "${node}" -- bash -c "echo ${md5sum_file} > /host/var/local/kata-containers.rpm.md5sum"
done