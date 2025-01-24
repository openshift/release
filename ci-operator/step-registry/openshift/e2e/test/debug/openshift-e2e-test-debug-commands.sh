#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "DEBUG....."
mkdir $SHARED_DIR/nodes
for n in `oc get no |grep -v "^NAME" |cut -d ' ' -f1`; do
    echo $n
    oc debug --to-namespace default node/$n -- ls -l /host/dev/disk/by-id |tee $SHARED_DIR/nodes/$n.out
done
echo "DEBUG ----"
echo $SHARED_DIR
ls -al $SHARED_DIR/nodes
echo "DEBUG ---- DONE"
