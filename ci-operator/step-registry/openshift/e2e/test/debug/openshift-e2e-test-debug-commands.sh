#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "DEBUG....."
for n in `oc get no |grep -v "^NAME" |cut -d ' ' -f1`; do
    OUT=$SHARED_DIR/disk-by-id-for-$n.out
    oc debug --to-namespace default node/$n -- chroot /host /usr/bin/bash -c "ls -l /dev/disk/by-id |grep \$(basename \$(head -1 /proc/mounts |cut -d ' ' -f1)) |cut -d ' ' -f9" >$OUT
    echo "NODE $n"
    cat $OUT
done
echo "DEBUG ----"
echo $SHARED_DIR
ls -al $SHARED_DIR
echo "DEBUG ---- DONE"
