#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts proxy command ************"

# Fetch packet basic configuration
# shellcheck disable=SC1090
source "${SHARED_DIR}/packet-conf.sh"

# Setup a squid proxy for accessing the cluster
# shellcheck disable=SC2087 # We need $CLUSTERTYPE in the here doc to expand locally
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
set -x
# CENTOS STREAM 8 IS END OF LIFE
# FIXME:Update to CentOS Stream 9
# Temporary workaround here https://forums.centos.org/viewtopic.php?t=78708&start=30
cat /etc/os-release
source /etc/os-release
if [[ "\$NAME" == "CentOS Stream" && "\$VERSION_ID" == "8" ]]; then
    sudo sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*
    sudo sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*
    sudo dnf clean all
fi
set +x

# Read the host's /etc/hosts, and create podman --add-host entries for
# each metalkube.org entry. This lets the squid container know all the
# DNS records for things like the local registry. A simple bind mount
# of /etc/hosts doesn't work because docker/podman adds entries for the
# container itself too.
generate_add_hosts() {
  local hosts_file="/etc/hosts"

  while read -r ip domain; do
    # Skip comments and blank lines
    [[ "\$ip" =~ ^#.*$ || -z "\$ip" ]] && continue

    # Check if the domain contains "metalkube.org"
    if [[ "\$domain" == *"metalkube.org"* ]]; then
      echo "--add-host \$domain:\$ip"
    fi
  done < "\$hosts_file"
}

sudo dnf install -y podman firewalld

# The default "10:30:100" results in connections being rejected
# Password auth is disabled so we can bump this up a bit and make it
# less likely we hit "ssh_exchange_identification: Connection closed by remote host"
sudo sed -i -e 's/.*MaxStartups.*/MaxStartups 20:10:100/g' /etc/ssh/sshd_config
sudo systemctl restart sshd

# Setup squid proxy for accessing cluster
cat <<SQUID>\$HOME/squid.conf
acl cluster dstdomain .metalkube.org .ocpci.eng.rdu2.redhat.com .okd.on.massopen.cloud .p1.openshiftapps.com sso.redhat.com
http_access allow cluster
http_access deny all
http_port 8213
debug_options ALL,2
coredump_dir /var/spool/squid
SQUID

sudo systemctl start firewalld
sudo firewall-cmd --add-port=8213/tcp --permanent
sudo firewall-cmd --reload

EXTRAVOLUMES=
if [[ "$CLUSTERTYPE" == "baremetal" ]] ; then
    EXTRAVOLUMES="--volume /etc/resolv.conf:/etc/resolv.conf"
fi

sudo setenforce 0

sudo podman run -d --rm \
     --net host \
     --volume \$HOME/squid.conf:/etc/squid/squid.conf \$EXTRAVOLUMES \
     --name external-squid \
     --dns 127.0.0.1 \
     \$(generate_add_hosts) quay.io/openshifttest/squid-proxy:multiarch
EOF

CIRFILE=$SHARED_DIR/cir
PROXYPORT=8213
if [ -f $CIRFILE ] ; then
    PROXYPORT=$(jq -r ".extra | select( . != \"\") // {}" < $CIRFILE | jq ".ofcir_port_proxy // 8213" -r)
fi


cat <<EOF> "${SHARED_DIR}/proxy-conf.sh"
export PROXYPORT=${PROXYPORT}
export HTTP_PROXY=http://${IP}:${PROXYPORT}/
export HTTPS_PROXY=http://${IP}:${PROXYPORT}/
export NO_PROXY="static.redhat.com,redhat.io,quay.io,openshift.org,openshift.com,svc,amazonaws.com,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"

export http_proxy=http://${IP}:${PROXYPORT}/
export https_proxy=http://${IP}:${PROXYPORT}/
export no_proxy="static.redhat.com,redhat.io,quay.io,openshift.org,openshift.com,svc,amazonaws.com,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,localhost,127.0.0.1"
EOF
