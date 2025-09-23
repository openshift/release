#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

if [ "${ENABLE_DEBUG_CONSOLE_GATHER:-}" != "true" ]; then
  echo "ENABLE_DEBUG_CONSOLE_GATHER is not set, exiting..."
  exit 0
fi

PACKET_CONF="${SHARED_DIR}/packet-conf.sh"
if [ ! -f "${PACKET_CONF}" ]; then
    echo "Error: packet-conf.sh not found at $PACKET_CONF"
    exit 1
fi

PASSWD="${SHARED_DIR}/console.passwd"
if [ ! -f "${PASSWD}" ]; then
    echo "Error: SSH key file not found at $SSH_KEY_FILE"
    exit 1
fi

# Fetch packet basic configuration
# shellcheck disable=SC1090
source "${PACKET_CONF}"
# Fetch console passwd
set +x
# shellcheck disable=SC1090
source "${PASSWD}"
set -x

tmpdir=$(mktemp -d -u)
function getlogs() {
  echo "### Downloading logs..."
  scp -r "${SSHOPTS[@]}" "root@${IP}:${tmpdir}" "${ARTIFACT_DIR}/ovn-debug-console-gather" || true
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF

source ~/dev-scripts-additional-config

firstNodeNotReady=\$(oc get nodes -o json | jq -r '[.items[] | select(([.status.conditions[] | select(.type=="Ready") | select(.status!="True")] | length)==1) | .status.nodeInfo.systemUUID][0] // empty')
if [ -z "\$firstNodeNotReady" ]; then
  echo "All nodes are healthy, nothing to do"
  exit 0
fi

output=console-gather.\${firstNodeNotReady}.tar.xz

echo "### Gathering logs for node \$firstNodeNotReady"
dnf install -y expect
mkdir ${tmpdir}
expect -c "
    set prompt {][$]}
    set return \"\r\"
    set disconnect \"\x1d\"

    spawn virsh console --force \$firstNodeNotReady
    match_max -i \\\$spawn_id 3000000
    expect_before {
      timeout { exit 1 }
    }

    set timeout 30

    # login
    expect -re {Escape character.*}
    send \\\$return
    expect -re {.*login: \$}
    send {core}
    send \\\$return
    expect {Password:}
    send {${PASSWD}}
    send \\\$return
    expect -re \\\$prompt

    # create temp dir
    send {mkdir ${tmpdir}}
    send \\\$return
    expect -re \\\$prompt
    send {cd ${tmpdir}}
    send \\\$return
    expect -re \\\$prompt
    send {chmod a+rw .}
    send \\\$return
    expect -re \\\$prompt

    # collect information

    # sos report
    set timeout 600
    send {toolbox sos report --batch -q -o logs,networking,networkmanager,conntrack,openvswitch,frr,crio -k crio.logs=on --tmp-dir ${tmpdir}}
    send \\\$return
    expect -re \\\$prompt
    set timeout 30

    # get frr pod id
    send {frr=\\\$(sudo crictl ps --label io.kubernetes.container.name=frr -o json | jq -r '.[] | .[0] | .id')}
    send \\\$return
    expect -re \\\$prompt

    # get frr info
    send {sudo crictl exec \\\$frr vtysh -c 'show running-conf' > ${tmpdir}/frr.ip_route_vrf_all.\${firstNodeNotReady}.txt}
    send \\\$return
    expect -re \\\$prompt
    send {sudo crictl exec \\\$frr vtysh -c 'show ip route vrf all' > ${tmpdir}/frr.ip_route_vrf_all.\${firstNodeNotReady}.txt}
    send \\\$return
    expect -re \\\$prompt
    send {sudo crictl exec \\\$frr vtysh -c 'show ip bgp vrf all ipv4 summary' > ${tmpdir}/frr.ip_bgp_vrf_all_ipv4_summary.\${firstNodeNotReady}.txt}
    send \\\$return
    expect -re \\\$prompt
    send {sudo crictl exec \\\$frr vtysh -c 'show bgp vrf all ipv4' > ${tmpdir}/frr.bgp_vrf_all_ipv4.\${firstNodeNotReady}.txt}
    send \\\$return
    expect -re \\\$prompt
    send {sudo crictl exec \\\$frr vtysh -c 'show bgp vrf all ipv4 neighbor' > ${tmpdir}/frr.bgp_vrf_all_ipv4_neighbor.\${firstNodeNotReady}.txt}
    send \\\$return
    expect -re \\\$prompt
    send {sudo crictl exec \\\$frr vtysh -c 'show bfd vrf all peer' > ${tmpdir}/frr.bfd_vrf_all_peer.\${firstNodeNotReady}.txt}
    send \\\$return
    expect -re \\\$prompt


    # get 15s tcpdump sample
    send {toolbox tcpdump -i any -eennvv -G 10 -W 1 -w /host/${tmpdir}/tcpdump.pcap}
    send \\\$return
    expect -re \\\$prompt

    send {sudo chmod -R a+r *}
    send \\\$return
    expect -re \\\$prompt

    # transfer the information via serial console
    # 1. tar everything
    # 2. base64 encode
    # 3. split in 2M chunks to avoid overflowing buffer and kernel soft locks
    # 4. cat on one side, read from the other
    send {tar cJf ${tmpdir}/\${output} --exclude=\${output} -C ${tmpdir} .}
    send \\\$return
    expect -re \\\$prompt
    send {base64 -w0 ${tmpdir}/\${output} > ${tmpdir}/\${output}.b64}
    send \\\$return
    expect -re \\\$prompt
    send {split -b 2M -d --suffix-length=6 ${tmpdir}/\${output}.b64 ${tmpdir}/\${output}.b64.} 
    send \\\$return
    expect -re \\\$prompt
    send {for f in \\\$(ls -1 ${tmpdir}/\${output}.b64.*); do cat \\\$f; sleep 1; done}
    log_user 0
    send \\\$return
    set fd [open "${tmpdir}/\${output}.b64" w]
    expect -re {\r([-A-Za-z0-9+/]+={0,3})} {
      puts -nonewline \\\$fd \\\$expect_out(1,string)
      expect {
	      -re {^([-A-Za-z0-9+/]+={0,3})} { puts -nonewline \\\$fd \\\$expect_out(1,string) ; exp_continue }
	      -re {^(={0,3})[^-A-Za-z0-9+/=]} { puts -nonewline \\\$fd \\\$expect_out(1,string) }
      }
    }
    close \\\$fd
    log_user 1
    expect -re \\\$prompt

    # logout
    send {exit}
    send \\\$return
    expect -re {.*login: \$}
    send \\\$disconnect
    expect eof
"

# decode & untar
cd "$tmpdir"
base64 -d \${output}.b64 > \${output}
tar xvf \${output}
rm \${output}.b64 \${output}

EOF
