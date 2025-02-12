#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "DEBUG....."
OUT=$SHARED_DIR/disk-by-id.out
echo $OUT
rm -f $OUT
for n in `oc get no |grep -v "^NAME" |cut -d ' ' -f1`; do
    echo $n >> $OUT
    oc debug --to-namespace default node/$n -- ls -l /host/dev/disk/by-id >> $OUT
    echo "END-OF-$n" >> $OUT
done
echo "DEBUG ----"
echo $SHARED_DIR
ls -al $SHARED_DIR
echo "DEBUG ---- DONE"
