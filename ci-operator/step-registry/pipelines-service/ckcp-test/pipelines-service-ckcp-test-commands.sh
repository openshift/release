#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

oc version
yq --version
which argocd
echo "list directories ...."
ls -l
