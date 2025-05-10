#!/bin/bash
#
# Download and copy the kata containers RPM to /host/var/local/kata-containers.rpm
# on each worker node. The RPM is going to be installed by the test automation code.

# By default it's going to skip the rpm installation
[[ "${INSTALL_KATA_RPM}" != "true" ]] && exit 0

BREW_USER=$(cat /usr/local/sandboxed-containers-operator-ci-secrets/secrets/BREW_USER)
BREW_PASSWORD=$(cat /usr/local/sandboxed-containers-operator-ci-secrets/secrets/BREW_PASSWORD)

md5sum_file="${KATA_RPM_BUILD_MD5SUM}  kata-containers.rpm"
curl -L -k -o kata-containers.rpm -u "${BREW_USER}:${BREW_PASSWORD}" "${KATA_RPM_BUILD_URL}"
echo "${md5sum_file}" | md5sum -c -

nodes=$(oc get node -l node-role.kubernetes.io/worker= -o name)
for node in $nodes;do
    dd if=kata-containers.rpm| oc debug -n default -T "${node}" -- dd of=/host/var/local/kata-containers.rpm
    oc debug -n default -T "${node}" -- bash -c "echo ${md5sum_file} > /host/var/local/kata-containers.rpm.md5sum"
done