#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail



cp -L $KUBECONFIG /tmp/kubeconfig

export KUBECONFIG=/tmp/kubeconfig

oc whoami
sleep 5400