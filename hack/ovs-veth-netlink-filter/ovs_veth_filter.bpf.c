/* SPDX-License-Identifier: GPL-2.0 */
#include "vmlinux.h"

#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

#define AF_NETLINK 16
#define NETLINK_ROUTE 0

#define RTM_NEWLINK 16
#define RTM_DELLINK 17

#define IFLA_LINKINFO 18
#define IFLA_INFO_KIND 1

#define EPERM 1
#define MAX_NLMSGS 8
#define MAX_ATTRS 64

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 16);
    __type(key, __u32);       /* Netlink port ID, not process ID. */
    __type(value, __u8);
} target_portids SEC(".maps");

enum stat_index {
    STAT_TARGET_MESSAGES,
    STAT_DROPPED_VETH_MESSAGES,
    STAT_PARSE_FAILURES,
    STAT_MAX,
};

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, STAT_MAX);
    __type(key, __u32);
    __type(value, __u64);
} stats SEC(".maps");

static __always_inline void
count_stat(enum stat_index index)
{
    __u32 key = index;
    __u64 *value = bpf_map_lookup_elem(&stats, &key);

    if (value) {
        (*value)++;
    }
}

static __always_inline __u32
align4(__u32 value)
{
    return (value + 3) & ~3U;
}

/* Returns 1 for veth, 0 for another link kind, and -1 on malformed input. */
static __always_inline int
link_is_veth(const unsigned char *data, __u32 msg_offset, __u32 msg_len)
{
    __u32 offset = msg_offset + align4(sizeof(struct nlmsghdr))
                   + align4(sizeof(struct ifinfomsg));
    __u32 end = msg_offset + msg_len;

    for (int i = 0; i < MAX_ATTRS; i++) {
        struct rtattr rta;

        if (offset == end) {
            return 0;
        }
        if (offset > end || end - offset < sizeof(rta)
            || bpf_probe_read_kernel(&rta, sizeof(rta), data + offset)) {
            return -1;
        }
        if (rta.rta_len < sizeof(rta) || rta.rta_len > end - offset) {
            return -1;
        }

        if (rta.rta_type == IFLA_LINKINFO) {
            __u32 nested = offset + align4(sizeof(rta));
            __u32 nested_end = offset + rta.rta_len;

            for (int j = 0; j < MAX_ATTRS; j++) {
                struct rtattr info;

                if (nested == nested_end) {
                    return 0;
                }
                if (nested > nested_end
                    || nested_end - nested < sizeof(info)
                    || bpf_probe_read_kernel(&info, sizeof(info),
                                             data + nested)) {
                    return -1;
                }
                if (info.rta_len < sizeof(info)
                    || info.rta_len > nested_end - nested) {
                    return -1;
                }
                if (info.rta_type == IFLA_INFO_KIND) {
                    char kind[5] = {};

                    if (info.rta_len < sizeof(info) + sizeof(kind)
                        || bpf_probe_read_kernel(kind, sizeof(kind),
                                                 data + nested
                                                 + sizeof(info))) {
                        return -1;
                    }
                    return kind[0] == 'v' && kind[1] == 'e'
                           && kind[2] == 't' && kind[3] == 'h'
                           && kind[4] == '\0';
                }
                nested += align4(info.rta_len);
            }
            return -1;
        }
        offset += align4(rta.rta_len);
    }
    return -1;
}

SEC("lsm/socket_sock_rcv_skb")
int BPF_PROG(drop_ovs_veth_link_events, struct sock *sk,
             struct sk_buff *skb, int ret)
{
    struct netlink_sock *nlk;
    const unsigned char *data;
    __u32 portid, skb_len, offset = 0;
    __u16 family;
    __u8 *enabled;
    bool saw_veth = false;

    /* Preserve a denial returned by an earlier LSM program. */
    if (ret) {
        return ret;
    }

    family = BPF_CORE_READ(sk, __sk_common.skc_family);
    if (family != AF_NETLINK
        || BPF_CORE_READ(sk, sk_protocol) != NETLINK_ROUTE) {
        return 0;
    }

    /* struct sock is the first member of struct netlink_sock. */
    nlk = container_of(sk, struct netlink_sock, sk);
    portid = BPF_CORE_READ(nlk, portid);
    enabled = bpf_map_lookup_elem(&target_portids, &portid);
    if (!enabled || !*enabled) {
        return 0;
    }

    count_stat(STAT_TARGET_MESSAGES);
    data = BPF_CORE_READ(skb, data);
    skb_len = BPF_CORE_READ(skb, len);

    /* A drop applies to the complete skb.  Fail open unless every contained
     * netlink message is a well-formed veth link notification.
     */
    for (int i = 0; i < MAX_NLMSGS; i++) {
        struct nlmsghdr nlh;
        int is_veth;

        if (offset == skb_len) {
            if (saw_veth) {
                count_stat(STAT_DROPPED_VETH_MESSAGES);
                return -EPERM;
            }
            return 0;
        }
        if (offset > skb_len || skb_len - offset < sizeof(nlh)
            || bpf_probe_read_kernel(&nlh, sizeof(nlh), data + offset)
            || nlh.nlmsg_len < sizeof(nlh)
            || nlh.nlmsg_len > skb_len - offset) {
            count_stat(STAT_PARSE_FAILURES);
            return 0;
        }
        if (nlh.nlmsg_type != RTM_NEWLINK
            && nlh.nlmsg_type != RTM_DELLINK) {
            return 0;
        }

        is_veth = link_is_veth(data, offset, nlh.nlmsg_len);
        if (is_veth != 1) {
            if (is_veth < 0) {
                count_stat(STAT_PARSE_FAILURES);
            }
            return 0;
        }
        saw_veth = true;
        offset += align4(nlh.nlmsg_len);
    }

    /* The last bounded iteration may have consumed the end of the skb. */
    if (offset == skb_len && saw_veth) {
        count_stat(STAT_DROPPED_VETH_MESSAGES);
        return -EPERM;
    }

    /* More messages than the verifier-bounded loop: fail open. */
    count_stat(STAT_PARSE_FAILURES);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
