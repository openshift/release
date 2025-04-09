#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

for NODE in `oc -o custom-columns=NAME:.metadata.name get no --no-headers`; do
    echo "NODE $NODE"
    OUT=$SHARED_DIR/disk-by-id-for-$NODE.out
    ROOT_DISK=$(oc debug --to-namespace default node/$NODE -- chroot /host /usr/bin/bash -c "findmnt -o SOURCE --noheadings --nofsroot --mountpoint /sysroot")
    if [ -z $ROOT_DISK ]; then echo "root disk not found"; exit 1; fi
    echo "ROOT_DISK $ROOT_DISK"
    cat $OUT

    for SYMLINK in `cat $OUT`; do
	SYMLINK_PRESENT=$(oc debug --to-namespace default node/$NODE -- chroot /host /usr/bin/bash -c "if [ -L /dev/disk/by-id/$SYMLINK ]; then echo 1; else echo 0; fi")
	if [ $SYMLINK_PRESENT != "1" ]; then
	    echo "Missed symlink $SYMLINK for node $NODE"
	    exit 1
	fi
	DISK=$(oc debug --to-namespace default node/$NODE -- chroot /host /usr/bin/realpath /dev/disk/by-id/$SYMLINK)
	if [ $ROOT_DISK != $DISK ]; then
	    echo "MISMATCH for node $NODE: The symlink $SYMLINK exists, but points to disk $DISK, not $ROOT_DISK as expected"
	    exit 1
	fi
    done
done
