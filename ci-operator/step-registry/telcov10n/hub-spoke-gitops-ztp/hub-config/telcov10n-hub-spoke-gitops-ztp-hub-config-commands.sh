#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n hub configuration ************"
# Fix user IDs in a container
[ -e "$HOME/fix_uid.sh" ] && "$HOME/fix_uid.sh" || echo "$HOME/fix_uid.sh was not found" >&2
 
export KUBECONFIG=$SHARED_DIR/kubeconfig
until oc apply -k https://github.com/shaior/vse-carslab-hub/bootstrap/overlays/default?ref=hub-config; do sleep 3; done
