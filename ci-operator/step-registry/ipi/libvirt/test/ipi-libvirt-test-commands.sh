#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ Test command ************"

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

# Initial check
if [[ "${CLUSTER_TYPE}" != "libvirt-ppc64le" ]] && [[ "${CLUSTER_TYPE}" != "libvirt-s390x" ]] ; then
    echo "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 0
fi

# Tests execution
set +e
openshift-tests run "openshift/conformance/parallel" --from-repository=quay.io/multi-arch/community-e2e-images \
  -o "${ARTIFACT_DIR}/e2e.log" \
  --junit-dir "${ARTIFACT_DIR}/junit" &
wait "$!"
rv=$?

echo "### Fetching results"
tar -czf - /tmp/artifacts | tar -C "${ARTIFACT_DIR}" -xzf -
set -e
echo "### Done! (${rv})"
exit $rv
