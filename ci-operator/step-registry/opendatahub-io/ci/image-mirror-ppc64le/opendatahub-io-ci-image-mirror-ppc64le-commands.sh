#!/bin/bash

export HOME=/tmp/home
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}/containers"
cd "$HOME" || exit 1


# what env?
cat /etc/os-release
uname -a

# user details
whoami
groups


# is docker present?
which docker

# is podman present?
which podman
