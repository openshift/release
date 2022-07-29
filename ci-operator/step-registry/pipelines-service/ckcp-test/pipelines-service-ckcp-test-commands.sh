#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc version
argocd version --client
yq --version
echo "list directories ...."
ls -l
tree
