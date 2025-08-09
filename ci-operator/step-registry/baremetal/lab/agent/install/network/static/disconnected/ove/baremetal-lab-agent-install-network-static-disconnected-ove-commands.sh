#!/bin/bash

set -o errtrace
set -o errexit
set -o pipefail
set -o nounset

# Trap to kill children processes
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM ERR

sleep 7m
cp "/tmp/kubeconfig" "${SHARED_DIR}/"
cp "/tmp/kubeadmin-password" "${SHARED_DIR}/"
cp "/tmp/proxy-conf.sh" "${SHARED_DIR}/"
cp "/tmp/mirror_registry_url" "${SHARED_DIR}/"