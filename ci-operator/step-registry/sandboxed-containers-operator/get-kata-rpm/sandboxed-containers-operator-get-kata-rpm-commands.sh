#!/bin/bash
#
# Download and copy the kata containers RPM to /host/var/local/kata-containers.rpm
# on each worker node. The RPM is going to be installed by the test automation code.

# By default it's going to skip the rpm installation
[[ "${INSTALL_KATA_RPM}" != "true" ]] && exit 0

cd /tmp || exit 1

arch=$(uname -m)
if [ -n "${KATA_RPM_BUILD_TASK}" ];then
    KATA_RPM_BASE_URL=$(cat /usr/local/sandboxed-containers-operator-ci-secrets/secrets/KATA_RPM_BUILD_TASK_BASE_URL)
    # To the base URL it's appended the "last four digits of task ID"/"full task ID"
    KATA_RPM_BASE_URL+="/${KATA_RPM_BUILD_TASK: -4}/${KATA_RPM_BUILD_TASK}"
else
    ver=$(echo "$KATA_RPM_VERSION" | cut -d- -f1)
    build=$(echo "$KATA_RPM_VERSION" | cut -d- -f2)
    KATA_RPM_BASE_URL=$(cat /usr/local/sandboxed-containers-operator-ci-secrets/secrets/KATA_RPM_BASE_URL)
    KATA_RPM_BASE_URL+="/${ver}/${build}/${arch}"
fi

brew_auth="$(oc get -n openshift-config secret/pull-secret -ojson  | jq -r '.data.".dockerconfigjson"' |  base64 -d | jq -r '.auths."registry.redhat.io".auth' | base64 -d)"

pkgs="kata-containers"

for pkg in ${pkgs}; do
    rpm="${pkg}-${KATA_RPM_VERSION}.${arch}.rpm"
    echo "Getting ${rpm}"
    KATA_RPM_BUILD_URL="${KATA_RPM_BASE_URL}/${rpm}"
    OUTPUT="$(curl -L -k -o ${rpm} -u "${brew_auth}" "${KATA_RPM_BUILD_URL}" 2>&1)"
    err=$?
    if [ $err -ne 0 ]; then
        echo "ERROR: curl error ${err} trying to get ${KATA_RPM_BUILD_URL}"
        echo "ERROR: ${OUTPUT}"
        exit 2
    fi

    # checks for a bad URL
    if [ "$(grep -q 'title.*404 Not Found' ${rpm})" ] && [ "$(grep -q 'p.The requested URL was not found' ${rpm})" ]; then
        echo "ERROR: curl couldn't find ${KATA_RPM_BUILD_URL} $(head -20 ${rpm})"
        exit 3
    fi

    KATA_RPM_MD5SUM=$(md5sum ${rpm} | cut -d' ' -f1)

    # Upload and check against KATA_RPM_MD5SUM
    FAILED_NODES=""
    nodes=$(oc get node -l node-role.kubernetes.io/worker= -o name)
    for node in $nodes;do
        dd if=${rpm}| oc debug -n default -T "${node}" -- dd of=/host/var/local/${rpm}
        OUTPUT=$(oc debug -n default "${node}" -- bash -c "md5sum  /host/var/local/${rpm}")
        if [ "$(echo "${OUTPUT}" | grep -q "${KATA_RPM_MD5SUM}")" ]; then
            FAILED_NODES="${node}:${OUTPUT} ${FAILED_NODES}"
        fi
    done

    # check for failures
    if [ "${FAILED_NODES}" != "" ]; then
        echo "calculated checksum: ${KATA_RPM_MD5SUM}"
        echo "ERROR: uploads failed on nodes ${FAILED_NODES}"
        exit 4
    fi
done