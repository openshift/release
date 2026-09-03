#!/usr/bin/env bash
set -euo pipefail

source_dir=/opt/ovs-veth-filter
run_dir=/run/ovs-veth-filter
pin_dir=/sys/fs/bpf/ovs_veth_netlink_filter
map_dir=$pin_dir/maps
current_portid=
current_key=

portid_key()
{
    local hex

    hex=$(printf '%08x' "$1")
    case $(uname -m) in
        s390x)
            printf '%s %s %s %s\n' \
                "${hex:0:2}" "${hex:2:2}" "${hex:4:2}" "${hex:6:2}"
            ;;
        *)
            printf '%s %s %s %s\n' \
                "${hex:6:2}" "${hex:4:2}" "${hex:2:2}" "${hex:0:2}"
            ;;
    esac
}

delete_key()
{
    if [[ -n $current_key && -e $map_dir/target_portids ]]; then
        # shellcheck disable=SC2086
        bpftool map delete pinned "$map_dir/target_portids" \
            key hex $current_key 2>/dev/null || true
    fi
    current_portid=
    current_key=
}

cleanup()
{
    delete_key
    rm -f "$pin_dir/link" "$map_dir/target_portids" "$map_dir/stats"
    rmdir "$map_dir" "$pin_dir" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

if [[ ! -r /sys/kernel/btf/vmlinux ]]; then
    echo "node does not expose /sys/kernel/btf/vmlinux" >&2
    exit 1
fi
if [[ ! -r /sys/kernel/security/lsm ]] \
   || ! grep -qw bpf /sys/kernel/security/lsm; then
    echo "BPF LSM is not active on this node" >&2
    exit 1
fi

mkdir -p "$run_dir"
# Recent kernel BTF can emit kfunc prototypes in vmlinux.h.  They are not used
# here and may conflict with helper declarations from the container's libbpf.
bpftool btf dump file /sys/kernel/btf/vmlinux format c \
    | sed '/^extern .* __weak __ksym;$/d' \
    > "$run_dir/vmlinux.h"
clang -g -O2 -target bpf -I "$run_dir" \
    -c "$source_dir/ovs_veth_filter.bpf.c" \
    -o "$run_dir/ovs_veth_filter.bpf.o"

# Remove pins left by an abruptly terminated predecessor on this node.
rm -f "$pin_dir/link" "$map_dir/target_portids" "$map_dir/stats"
mkdir -p "$map_dir"
bpftool prog load "$run_dir/ovs_veth_filter.bpf.o" "$pin_dir/link" \
    pinmaps "$map_dir" autoattach

while true; do
    ovs_pid=$(pidof ovs-vswitchd 2>/dev/null | awk '{ print $1 }')
    if [[ -z $ovs_pid ]]; then
        delete_key
        echo "waiting for ovs-vswitchd" >&2
        sleep 5
        continue
    fi

    portid=$($source_dir/find-portid.sh "$ovs_pid" 2>/dev/null || true)
    if [[ -z $portid ]]; then
        delete_key
        echo "waiting for the OVS RTNLGRP_LINK socket (pid $ovs_pid)" >&2
        sleep 5
        continue
    fi

    if [[ $portid != "$current_portid" ]]; then
        new_key=$(portid_key "$portid")
        # Enable the new socket before forgetting a socket from an old process.
        # shellcheck disable=SC2086
        bpftool map update pinned "$map_dir/target_portids" \
            key hex $new_key value hex 01
        delete_key
        current_portid=$portid
        current_key=$new_key
        echo "filtering veth link events for OVS netlink port ID $portid"
    fi
    sleep 5
done
