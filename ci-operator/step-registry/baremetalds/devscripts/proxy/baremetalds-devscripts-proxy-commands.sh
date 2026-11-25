#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts proxy command ************"

# Fetch packet basic configuration
# shellcheck disable=SC1090
source "${SHARED_DIR}/packet-conf.sh"

# Optional destination ACL, by IP rather than by domain.
#
# The "cluster" acl below is dstdomain-only, so a bare address never matches it
# and "http_access deny all" rejects the CONNECT with 403 Forbidden. That is a
# problem for anything addressed by IP on the dev-scripts networks -- notably a
# HostedCluster API endpoint on a MetalLB address, which has no DNS name. Steps
# that need it would otherwise have to append the address to this file and
# restart squid themselves, which only works for steps that run after the
# address exists and leaves earlier steps unable to reach it at all.
#
# Empty by default, so lanes that do not set it get byte-identical squid config.
PROXY_DST_ACL=""
PROXY_DST_ALLOW=""
if [[ -n "${PROXY_ALLOWED_DST_CIDRS:-}" ]]; then
  PROXY_DST_ACL="acl cluster_net dst ${PROXY_ALLOWED_DST_CIDRS}"
  PROXY_DST_ALLOW="http_access allow CONNECT cluster_net
http_access allow safe_http_port safe_http_methods cluster_net"
  echo "Allowing proxied access to: ${PROXY_ALLOWED_DST_CIDRS}"
fi

# Setup a squid proxy for accessing the cluster
# shellcheck disable=SC2087 # We need $CLUSTERTYPE in the here doc to expand locally
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'
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

sudo dnf install -y container-tools crun podman firewalld

# The default "10:30:100" results in connections being rejected
# Password auth is disabled so we can bump this up a bit and make it
# less likely we hit "ssh_exchange_identification: Connection closed by remote host"
sudo sed -i -e 's/.*MaxStartups.*/MaxStartups 20:10:100/g' /etc/ssh/sshd_config
sudo systemctl restart sshd

# Setup squid proxy for accessing cluster
cat <<SQUID>\$HOME/squid.conf
acl cluster dstdomain .metalkube.org .test-infra-cluster.redhat.com .ocpci.eng.rdu2.redhat.com .p1.openshiftapps.com sso.redhat.com
${PROXY_DST_ACL}

acl allowed_ssl_ports port 443 5000 6443
acl CONNECT method CONNECT
acl safe_http_port port 80
acl safe_http_methods method GET HEAD

http_access deny CONNECT !allowed_ssl_ports
http_access allow CONNECT cluster
http_access allow safe_http_port safe_http_methods cluster
${PROXY_DST_ALLOW}
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
     quay.io/openshifttest/squid-proxy:multiarch
EOF

CIRFILE=$SHARED_DIR/cir
PROXYPORT=8213
if [ -f "$CIRFILE" ] ; then
    PROXYPORT=$(jq -r ".extra | select( . != \"\") // {}" < "$CIRFILE" | jq ".ofcir_port_proxy // 8213" -r)
fi


cat <<EOF> "${SHARED_DIR}/proxy-conf.sh"
export PROXYPORT=${PROXYPORT}
export HTTP_PROXY=http://${IP}:${PROXYPORT}/
export HTTPS_PROXY=http://${IP}:${PROXYPORT}/
export NO_PROXY="static.redhat.com,redhat.io,quay.io,openshift.org,openshift.com,svc,amazonaws.com,r2.cloudflarestorage.com,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,workers.dev,localhost,127.0.0.1"

export http_proxy=http://${IP}:${PROXYPORT}/
export https_proxy=http://${IP}:${PROXYPORT}/
export no_proxy="static.redhat.com,redhat.io,quay.io,openshift.org,openshift.com,svc,amazonaws.com,r2.cloudflarestorage.com,github.com,githubusercontent.com,google.com,googleapis.com,fedoraproject.org,cloudfront.net,workers.dev,localhost,127.0.0.1"
EOF
