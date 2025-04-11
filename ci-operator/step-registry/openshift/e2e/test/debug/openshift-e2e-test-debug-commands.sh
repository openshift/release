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
    oc debug --to-namespace default node/$NODE -- chroot /host /usr/bin/bash -c "for SYMLINK in \$(ls /dev/disk/by-id); do if [ \$(realpath /dev/disk/by-id/\$SYMLINK) == $ROOT_DISK ]; then echo \$SYMLINK ; fi; done" >$OUT
    cat $OUT
done
