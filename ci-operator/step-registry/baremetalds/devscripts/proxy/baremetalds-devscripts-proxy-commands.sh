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
sudo dnf install -y podman firewalld

# TODO: we need to fix the IPv6 job and remove this ASAP.
# Using vault for the anything but the short term isn't a good solution
# https://bugzilla.redhat.com/show_bug.cgi?id=2087096
if ! grep -iq Centos /etc/redhat-release ; then
    rm -f /etc/yum.repos.d/*
    for REPO in BaseOS AppStream extras ; do
        echo -e "[\$REPO]\nname=\$REPO\nbaseurl=https://dl.rockylinux.org/vault/rocky/8.5/\$REPO/x86_64/os/\nenabled=1\ngpgcheck=0\n" >> /etc/yum.repos.d/rocky.repo
    done
fi

# Setup squid proxy for accessing cluster
cat <<SQUID>\$HOME/squid.conf
acl cluster dstdomain .metalkube.org .ocpci.eng.rdu2.redhat.com
http_access allow cluster
http_access deny all
http_port 8213
debug_options ALL,2
dns_v4_first on
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
     quay.io/sameersbn/squid:latest
EOF

cat <<EOF> "${SHARED_DIR}/proxy-conf.sh"
export HTTP_PROXY=http://${IP}:8213/
export HTTPS_PROXY=http://${IP}:8213/
export NO_PROXY="static.redhat.com,redhat.io,quay.io,openshift.org,openshift.com,svc,amazonaws.com,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"

export http_proxy=http://${IP}:8213/
export https_proxy=http://${IP}:8213/
export no_proxy="static.redhat.com,redhat.io,quay.io,openshift.org,openshift.com,svc,amazonaws.com,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"
EOF
