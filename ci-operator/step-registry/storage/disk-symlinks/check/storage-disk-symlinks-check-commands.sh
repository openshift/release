#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

for NODE in `oc -o custom-columns=NAME:.metadata.name get nodes --no-headers`; do
    echo "NODE $NODE"
    OUT=$SHARED_DIR/disk-by-id-for-$NODE.out
    ROOT_DISK=$(oc debug --quiet --to-namespace default node/$NODE -- chroot /host /usr/bin/bash -c "findmnt -o SOURCE --noheadings --nofsroot --mountpoint /sysroot")
    if [ -z $ROOT_DISK ]; then echo "root disk not found"; exit 1; fi
    echo "ROOT_DISK $ROOT_DISK"
    cat $OUT

    SUCCESS="yes"

    for SYMLINK in `cat $OUT`; do
	SYMLINK_PRESENT=$(oc debug --quiet --to-namespace default node/$NODE -- chroot /host /usr/bin/bash -c "if [ -L /dev/disk/by-id/$SYMLINK ]; then echo 1; else echo 0; fi")
	if [ $SYMLINK_PRESENT != "1" ]; then
	    echo "Missed symlink $SYMLINK for node $NODE"
	    SUCCESS="no"
	    continue
	fi
	DISK=$(oc debug --quiet --to-namespace default node/$NODE -- chroot /host /usr/bin/realpath /dev/disk/by-id/$SYMLINK)
	if [ $ROOT_DISK != $DISK ]; then
	    echo "Mismatch for node $NODE: The symlink $SYMLINK exists, but points to disk $DISK, not $ROOT_DISK as expected"
	    SUCCESS="no"
	fi
    done

    if [ $SUCCESS != "yes" ]; then
	exit 1
    fi
    echo "Symlinks of root disk $DISK on the node $NODE are OK"
done
