#
# This is the image that is used to build and push manifest list images
# for release images
#
# The standard name for this image is openshift/origin-release:manifest-builder
#
FROM centos:7
MAINTAINER  Jason DeTiberus <jdetiber@redhat.com>

ENV GOPATH=/go
ENV PATH=$PATH:$GOPATH/bin

COPY cbs-paas7-openshift-multiarch-el7-build.repo /etc/yum.repos.d/
COPY build.sh /build/

RUN yum install -y epel-release && \
    rpm -V epel-release && \
    INSTALL_PKGS="git golang jq" && \
    yum install -y $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    yum clean all && \
    go get github.com/estesp/manifest-tool && \
    chgrp -R 0 /build && \
    chmod -R g=u /build && \
    chmod g+x /build/build.sh

CMD ["/build/build.sh"]
