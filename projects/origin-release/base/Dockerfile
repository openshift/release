#
# This is the image that controls the base dependencies for
# the standard build environment for releasing OpenShift Origin.
#
# The standard name for this image is openshift/origin-release:base
#
FROM        centos:7
MAINTAINER  Steve Kuznetsov <skuznets@redhat.com>

COPY cbs-paas7-openshift-multiarch-el7-build.repo /etc/yum.repos.d/
RUN yum install -y epel-release && \
	rpm -V epel-release && \
	INSTALL_PKGS="bc bind-utils bsdtar ceph-common createrepo device-mapper device-mapper-persistent-data e2fsprogs ethtool file findutils gcc git glibc-static gpgme gpgme-devel hostname iptables jq krb5-devel libassuan libassuan-devel lsof make mercurial nmap-ncat openssl protobuf-compiler rsync socat sysvinit-tools tar tito tree util-linux wget which xfsprogs zip" && \
    yum install -y $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    yum clean all && \
    touch /os-build-image && \
    git config --system user.name origin-release-container && \
    git config --system user.email origin-release@redhat.com