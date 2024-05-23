#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telcov10n cluster setup via agent command ************"
id
echo "Hello $(id -un)..."
# Fix user IDs in a container
[ -e "$HOME/fix_uid.sh" ] && "$HOME/fix_uid.sh" || echo "$HOME/fix_uid.sh was not found" >&2
id

echo "************ telcov10n sleep for a while for debugging purposes ************"
echo
echo "Hello $(id -un)..."
echo
printenv
sleep 10m