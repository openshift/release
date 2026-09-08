#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 OVS_VSWITCHD_PID" >&2
    exit 2
fi

pid=$1
proc_dir=/proc/$pid
[[ -r $proc_dir/net/netlink ]] || {
    echo "cannot read $proc_dir/net/netlink" >&2
    exit 1
}

declare -A socket_inodes=()
for fd in "$proc_dir"/fd/*; do
    link=$(readlink "$fd" 2>/dev/null || true)
    if [[ $link =~ ^socket:\[([0-9]+)\]$ ]]; then
        socket_inodes["${BASH_REMATCH[1]}"]=1
    fi
done

matches=()
while read -r sk protocol portid groups rmem wmem dump locks drops inode; do
    [[ $protocol == Eth ]] && continue
    # NETLINK_ROUTE is protocol 0.  The shared OVS rtnetlink notifier used by
    # route-table.c subscribes only to RTNLGRP_LINK, whose mask is bit zero.
    if [[ $protocol == 0 && $groups =~ ^0*1$ \
          && -n ${socket_inodes[$inode]+present} ]]; then
        matches+=("$portid")
    fi
done < "$proc_dir/net/netlink"

if [[ ${#matches[@]} -ne 1 ]]; then
    echo "expected one OVS NETLINK_ROUTE socket with groups=1; found ${#matches[@]}" >&2
    printf 'candidate port IDs: %s\n' "${matches[*]:-none}" >&2
    exit 1
fi

printf '%s\n' "${matches[0]}"
