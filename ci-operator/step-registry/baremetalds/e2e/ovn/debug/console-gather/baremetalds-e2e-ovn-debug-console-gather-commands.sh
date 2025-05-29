#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"
# Fetch console passwd
# shellcheck source=/dev/null
source "${SHARED_DIR}/console.passwd"

tmpdir=$(mktemp -d -u)
function getlogs() {
  echo "### Downloading logs..."
  scp -r "${SSHOPTS[@]}" "root@${IP}:${tmpdir}" "${ARTIFACT_DIR}/ovn-debug-console-gather"
}

# Gather logs regardless of what happens after this
trap getlogs EXIT

ssh "${SSHOPTS[@]}" "root@${IP}" bash - <<EOF
source ~/dev-scripts-additional-config
firstNodeNotReady=\$(oc get nodes -o json | jq -r '[.items[] | .status.nodeInfo.systemUUID'][0])
if [ -z "\$firstNodeNotReady" ]; then
  echo "All nodes are healthy, nothing to do"
  exit 0
fi
echo "### Gathering logs for node \$firstNodeNotReady"
dnf install -y expect
mkdir ${tmpdir}
expect -d -c "
    set timeout 30
    set prompt {][$]}
    spawn virsh console --force \$firstNodeNotReady
    match_max -i \\\$spawn_id 100000000
    expect_before {
      timeout { puts "timeout"; exit 1 }
    }
    expect -re \"Escape character.*\"
    send \"\r\"
    expect -re \".*login: \$\"
    send \"core\r\"
    expect \"Password:\"
    send \"${PASSWD}\r\"
    expect -re \\\$prompt
    send \"mkdir ${tmpdir}\r\"
    expect -re \\\$prompt
    send \"cd ${tmpdir}\r\"
    expect -re \\\$prompt
    set timeout 600
    send \"toolbox sos report --batch -q -o networking,conntrack,openvswitch,frr --tmp-dir ${tmpdir}\r\"
    expect -re \\\$prompt
    send \"sudo chmod +r *\r\"
    expect -re \\\$prompt
    log_user 0
    send \"base64 -w0 *.tar.xz\r\"
    expect -re {\r([-A-Za-z0-9+/]+={0,3})[^-A-Za-z0-9+/=]}
    log_user 1
    set fd [open "${tmpdir}/sos-report.\${firstNodeNotReady}.tar.xz.b64" w]
    puts -nonewline \\\$fd \\\$expect_out(1,string)
    close \\\$fd
    set timeout 30
    expect -re \\\$prompt
    send \"exit\r\"
    expect -re \".*login: \$\"
    send \"\x1d\"
    expect eof
"
EOF
