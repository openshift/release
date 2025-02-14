#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "DEBUG2....."
for n in `oc get no |grep -v "^NAME" |cut -d ' ' -f1`; do
  echo "NODE $n"
  CURRENT_ROOT_DISK=$(oc debug --to-namespace default node/$n -- chroot /host /usr/bin/bash -c "head -1 /proc/mounts |cut -d ' ' -f1")
  echo "CURRENT_ROOT_DISK $CURRENT_ROOT_DISK"
  cat $SHARED_DIR/disk-by-id-for-$n.out
  for p in $(cat $SHARED_DIR/disk-by-id-for-$n.out); do
    SYMLINK_PRESENT=$(oc debug --to-namespace default node/$n -- chroot /host /usr/bin/bash -c "if [ -L /dev/disk/by-id/$p ]; then echo 1; else echo 0; fi")
    if [ $SYMLINK_PRESENT != "1" ]; then
      echo "Missed symlink $p for node $n"
      exit 1
    fi
    DISK=$(oc debug --to-namespace default node/$n -- chroot /host /usr/bin/realpath /dev/disk/by-id/$p)
    if [ $CURRENT_ROOT_DISK != $DISK ]; then
      echo "MISMATCH for node $n: The symlink $p exists, but points to disk $DISK, not $CURRENT_ROOT_DISK as expected"
      exit 1
    fi
  done
done
echo "DEBUG2 ---- DONE"
