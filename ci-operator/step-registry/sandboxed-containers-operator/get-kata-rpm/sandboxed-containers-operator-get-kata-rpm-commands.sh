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

# get the output of curl in case there is an error
OUTPUT=$(curl -L -k -o kata-containers.rpm -u "${brew_auth}" "${KATA_RPM_BUILD_URL} 2>&1)"
err=$?
if [ $err -ne 0 ]
then
    echo "ERROR: curl error ${err} trying to get ${KATA_RPM_BUILD_URL}"
    echo "ERROR: ${OUTPUT}"
    exit $err
fi

echo "Debug:"
ls -l kata-containers.rpm || true

# no error from curl
# do some rudimentry checking of the contents.
# file kata-containers.rpm would show that it is a valid rpm

# checks for a bad URL
grep -q 'URL was not found' kata-containers.rpm
if [ $? -eq 0 ]
then
    echo "ERROR: curl couldn't find ${KATA_RPM_BUILD_URL}"
    # show the 1st 20 lines of the file
    head -20 kata_containers.rpm
    exit 2
fi

# calculate checksum
KATA_RPM_MD5SUM=$(md5sum kata-containers.rpm | cut -d' ' -f1)

# Upload and verify
FAILED_NODES=""
nodes=$(oc get node -l node-role.kubernetes.io/worker= -o name)
for node in $nodes;do
    dd if=kata-containers.rpm| oc debug -n default -T "${node}" -- dd of=/host/var/local/kata-containers.rpm
    OUTPUT=$(oc debug -n default "${node}" -- sh -c "md5sum  /host/var/local/kata-containers.rpm")
    if [ "${KATA_RPM_MD5SUM}" != $(echo ${OUTPUT} | cut -d ' ' -f1) ]
    then
        FAILED_NODES="${node}:${OUTPUT} ${FAILED_NODES}"
    fi
done

# check for failures
if [ ${FAILED_NODES} != "" ]
then
    echo "ERROR: uploads failed on nodes $FAILED_NODES"
    exit 4
fi
