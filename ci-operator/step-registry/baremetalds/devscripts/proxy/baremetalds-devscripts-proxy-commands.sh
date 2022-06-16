#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts proxy command ************"

# Fetch packet basic configuration
# shellcheck disable=SC1090
source "${SHARED_DIR}/packet-conf.sh"

# Setup a squid proxy for accessing the cluster
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

# TODO: remove me
# https://bugzilla.redhat.com/show_bug.cgi?id=2087096
sed -i -e 's/repo=.*/repo=rocky-AppStream-8.5/g' /etc/yum.repos.d/Rocky-AppStream.repo
sed -i -e 's/repo=.*/repo=rocky-BaseOS-8.5/g' /etc/yum.repos.d/Rocky-BaseOS.repo
sed -i -e 's/repo=.*/repo=rocky-extras-8.5/g' /etc/yum.repos.d/Rocky-Extras.repo

sudo dnf install -y podman firewalld

# Setup squid proxy for accessing cluster
cat <<SQUID>\$HOME/squid.conf
acl cluster dstdomain .metalkube.org
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

sudo podman run -d --rm \
     --net host \
     --volume \$HOME/squid.conf:/etc/squid/squid.conf \
     --name external-squid \
     --dns 127.0.0.1 \
     quay.io/sameersbn/squid:latest
EOF

cat <<EOF> "${SHARED_DIR}/proxy-conf.sh"
export HTTP_PROXY=http://${IP}:8213/
export HTTPS_PROXY=http://${IP}:8213/
export NO_PROXY="redhat.io,quay.io,redhat.com,openshift.org,openshift.com,svc,amazonaws.com,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"

export http_proxy=http://${IP}:8213/
export https_proxy=http://${IP}:8213/
export no_proxy="redhat.io,quay.io,redhat.com,openshift.org,openshift.com,svc,amazonaws.com,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,localhost,127.0.0.1"
EOF
