#!/bin/bash
# Gated wrapper around the shared ssh-bastion step so smoke jobs can share one
# test chain without always deploying a bastion. Deploy logic matches
# ci-operator/step-registry/ssh-bastion/ssh-bastion-commands.sh.

set -euo pipefail

if [[ "${MEDIK8S_S390X_SSH_BASTION:-false}" != "true" ]]; then
  echo "MEDIK8S_S390X_SSH_BASTION is not true; skipping ssh-bastion setup"
  exit 0
fi

echo "=== Deploying ssh-bastion for medik8s system-tests (s390x OZ) ==="

# Ensure our UID is in /etc/passwd (required for SSH from the step pod).
if ! whoami &>/dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo "/etc/passwd is not writeable, and user matching this uid is not found." >&2
    exit 1
  fi
fi

mkdir -p /tmp/client
curl -L --fail https://openshift-mirror-list.ci-systems.workers.dev/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz \
  | tar --directory=/tmp/client -xzf -
PATH=/tmp/client:$PATH
oc version --client

export SSH_BASTION_NAMESPACE=test-ssh-bastion
curl https://raw.githubusercontent.com/eparis/ssh-bastion/master/deploy/deploy.sh | bash -x

echo "=== ssh-bastion ready ==="
