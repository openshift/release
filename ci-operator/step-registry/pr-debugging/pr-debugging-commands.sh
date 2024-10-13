#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Fix user IDs in a container
[ -e "$HOME/fix_uid.sh" ] && "$HOME/fix_uid.sh" || echo "$HOME/fix_uid.sh was not found" >&2

 echo "************ telcov10n sleep for 3h for debugging purposes ************"
sleep 3h