#
# This is the image that is used to build the release images.
# It will inject the appropriate qemu-user-static images into
# the builds if the requested architecture is different from the
# host architecture.
#
# The standard name for this image is openshift/origin-release:release-image-builder
#
FROM centos:7
MAINTAINER  Jason DeTiberus <jdetiber@redhat.com>

ENV GOPATH=/go
ENV PATH=$PATH:$GOPATH/bin

COPY cbs-paas7-openshift-multiarch-el7-build.repo /etc/yum.repos.d/
COPY jdetiber-qemu-user-static.repo /etc/yum.repos.d/
COPY build.sh /build/

RUN yum install -y epel-release && \
    rpm -V epel-release && \
    INSTALL_PKGS="docker-client git golang jq qemu-user-static skopeo" && \
    yum install -y $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    yum clean all && \
    go get github.com/openshift/imagebuilder/cmd/imagebuilder && \
    chgrp -R 0 /build && \
    chmod -R g=u /build && \
    chmod g+x /build/build.sh

CMD ["/build/build.sh"]
