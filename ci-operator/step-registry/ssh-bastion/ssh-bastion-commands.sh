#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

mkdir -p /tmp/client
curl https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz | tar --directory=/tmp/client -xzf -
PATH=/tmp/client:$PATH
oc version --client

# Setting up ssh bastion host
export SSH_BASTION_NAMESPACE=test-ssh-bastion
curl https://raw.githubusercontent.com/eparis/ssh-bastion/master/deploy/deploy.sh | bash -x
