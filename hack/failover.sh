#!/bin/bash

# This script can be used to failover jobs from one cluster to another.
# Usage:
#
# Without parameters, the tool will simply dispatch jobs between all available clusters:
# ./hack/failover.sh
#
# Use the --disable-cluster option to mark a cluster as disabled and dispatch jobs between all enabled clusters:
# ./hack/failover.sh --disable-cluster=build01
#
# When the newly disabled cluster the default one, you need to set another one as a default:
# ./hack/failover.sh --disable-cluster=build01 --default-cluster=build02
#
# Use the --enable-cluster option to mark a cluster as enabled and dispatch jobs between all enabled clusters:
# ./hack/failover.sh --enable-cluster=build01
# OR with podman and macos, e.g.,
# CONTAINER_ENGINE=podman PROMTOKEN_TEMPLATE=/Users/hongkliu/repo/tmp/abc-script.XXXXXX ./hack/failover.sh --enable-cluster=build01

set -o errexit
set -o nounset
set -o pipefail

CONTAINER_ENGINE=${CONTAINER_ENGINE:-docker}
CONTAINER_ENGINE_OPTS=${CONTAINER_ENGINE_OPTS:-"--platform linux/amd64"}
VOLUME_MOUNT_FLAGS=${VOLUME_MOUNT_FLAGS:-:z}

if [ "$CONTAINER_ENGINE" == "podman" ] && [ "$(uname -s)" == "Darwin" ]; then
    # if you're running podman on macOS, don't set the SELinux label
    VOLUME_MOUNT_FLAGS=''
fi

if [ -z "${PROMTOKEN_TEMPLATE+x}" ]; then PROMTOKEN=$(mktemp); else PROMTOKEN=$(mktemp "${PROMTOKEN_TEMPLATE}"); fi
trap 'rm -f "${PROMTOKEN}"' EXIT

oc --context app.ci -n ci extract secret/app-ci-openshift-user-workload-monitoring-credentials --to=- --keys=sa.prometheus-user-workload.app.ci.token.txt > "${PROMTOKEN}"

set -x
${CONTAINER_ENGINE} pull ${CONTAINER_ENGINE_OPTS} registry.ci.openshift.org/ci/prow-job-dispatcher:latest
${CONTAINER_ENGINE} run ${CONTAINER_ENGINE_OPTS} --rm -v "$PWD:/release${VOLUME_MOUNT_FLAGS}" -v "${PROMTOKEN}:/promtoken${VOLUME_MOUNT_FLAGS}" registry.ci.openshift.org/ci/prow-job-dispatcher:latest "$@" \
    --target-dir=/release \
    --config-path=/release/core-services/sanitize-prow-jobs/_config.yaml \
    --prow-jobs-dir=/release/ci-operator/jobs \
    --prometheus-bearer-token-path=/promtoken
