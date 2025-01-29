#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "DEBUG2....."
for n in `oc get no |grep -v "^NAME" |cut -d ' ' -f1`; do
    echo $n
    oc debug --to-namespace default node/$n -- ls -l /host/dev/disk/by-id
done
echo "DEBUG2 ----"
echo $SHARED_DIR
ls -al $SHARED_DIR
echo "DEBUG2 --CAT--"
cat $SHARED_DIR/disk-by-id.out
echo "DEBUG2 ---- DONE"
