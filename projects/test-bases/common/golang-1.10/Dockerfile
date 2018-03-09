#
# This is the image that controls the standard build environment for releasing OpenShift Origin.
# It is responsible for performing a cross platform build of OpenShift.
#
# The standard name for this image is openshift/origin-release
#
FROM common-test-base:base
MAINTAINER  Steve Kuznetsov <skuznets@redhat.com>

ENV VERSION=1.10 \
    GOARM=5 \
    GOPATH=/go \
    GOROOT=/usr/local/go
ENV PATH=$PATH:$GOROOT/bin:$GOPATH/bin

ADD *.rpm /tmp/origin-rpm/
RUN INSTALL_PKGS="goversioninfo" && \
    yum install -y $INSTALL_PKGS /tmp/origin-rpm/*.rpm && \
    rpm -V $INSTALL_PKGS && \
    yum clean all && \
    curl https://storage.googleapis.com/golang/go$VERSION.linux-amd64.tar.gz | tar -C /usr/local -xzf - && \
    go get golang.org/x/tools/cmd/cover \
        golang.org/x/tools/cmd/goimports \
        github.com/tools/godep \
        github.com/golang/lint/golint \
        github.com/openshift/imagebuilder/cmd/imagebuilder

RUN chmod g+xw -R $GOPATH && \
    chmod g+xw -R $(go env GOROOT)
