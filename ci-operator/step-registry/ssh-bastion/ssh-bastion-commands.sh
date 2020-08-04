#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "${USER:-default}:x:$(id -u):$(id -g):Default User:$HOME:/sbin/nologin" >> /etc/passwd

# Setting up ssh bastion host
export SSH_BASTION_NAMESPACE=test-ssh-bastion
curl https://raw.githubusercontent.com/eparis/ssh-bastion/master/deploy/deploy.sh | bash -x
