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
    oc debug --quiet --to-namespace default node/$NODE -- chroot /host /usr/bin/bash -c "for SYMLINK in \$(ls /dev/disk/by-id); do if [ \$(realpath /dev/disk/by-id/\$SYMLINK) == $ROOT_DISK ]; then echo \$SYMLINK ; fi; done" >$OUT
    echo "Root disk symlinks discovered on $NODE:"
    cat $OUT
    echo ""
    cp $OUT $ARTIFACT_DIR

    OUT=$SHARED_DIR/lspci-$NODE.out
    echo "lspci -v"
    echo ""
    oc debug --quiet --to-namespace default node/$NODE -- chroot /host /usr/bin/bash -c "lspci -v" >$OUT
    cat $OUT
    echo ""
    cp $OUT $ARTIFACT_DIR

    OUT=$SHARED_DIR/dmesg-$NODE.out
    echo "dmesg -T |tail -300"
    echo ""
    oc debug --quiet --to-namespace default node/$NODE -- chroot /host /usr/bin/bash -c "dmesg -T |head -300" >$OUT
    cat $OUT
    echo ""
    cp $OUT $ARTIFACT_DIR
done
