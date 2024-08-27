#!/bin/bash

export HOME=/tmp/home
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "$HOME" || exit 1


# what env?
echo "-----EXP: cat /etc/os-release-----"
cat /etc/os-release
echo "-----EXP: uname -a-----"
uname -a

# user details
echo "-----EXP: woami-----"
whoami
echo "-----EXP: id-----"
id

# is docker present?
echo "-----EXP: which docker-----"
which docker

# is podman present?
echo "-----EXP: which podman-----"
which podman

# am i a sudoer?
sudo -l
