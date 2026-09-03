#!/usr/bin/env bash
set -euo pipefail

pin_dir=/sys/fs/bpf/ovs_veth_netlink_filter

test -e /run/ovs-veth-filter/ready
test -e "$pin_dir/link"
bpftool -j map dump pinned "$pin_dir/maps/target_portids" | \
    grep -Eq '"value"[[:space:]]*:[[:space:]]*1'
