#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "WAITING FOR DEBUG..."
while [ ! -f "/tmp/continue" ]
do
    sleep 10
done

echo "The upgrade path is:"
cat "${SHARED_DIR}/upgrade-edge"
echo "Drop the last upgrade hop to opt-in some extra actions before the last hop upgrade"
sed -i "s/\(.*\),.*$/\1/" "${SHARED_DIR}/upgrade-edge"
echo "The new upgrade path is:"
cat "${SHARED_DIR}/upgrade-edge"
