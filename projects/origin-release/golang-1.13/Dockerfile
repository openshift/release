#
# This is the image that controls the standard build environment for releasing OpenShift Origin.
# It is responsible for performing a cross platform build of OpenShift.
#
# The standard name for this image is openshift/origin-release
#
FROM        centos:7

ENV VERSION=1.13.1 \
    GOCACHE=/go/.cache \
    GOARM=5 \
    GOPATH=/go \
    GOROOT=/usr/local/go \
    LOGNAME=deadbeef
ENV PATH=$PATH:$GOROOT/bin:$GOPATH/bin

COPY cbs-paas7-openshift-multiarch-el7-build.repo /etc/yum.repos.d/
RUN yum install -y epel-release && \
    rpm -V epel-release && \
    INSTALL_PKGS="bc bind-utils bsdtar bzr ceph-common createrepo device-mapper device-mapper-persistent-data e2fsprogs ethtool file findutils gcc git glibc-static glib2-devel gpgme gpgme-devel hostname iptables jq krb5-devel libassuan libassuan-devel libseccomp-devel libvirt-devel lsof make mercurial nmap-ncat openssl protobuf-compiler rsync socat systemd-devel sysvinit-tools tar tito tree util-linux wget which xfsprogs zip goversioninfo" && \
    yum install -y $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    yum clean all && \
    touch /os-build-image && \
    git config --system user.name origin-release-container && \
    git config --system user.email origin-release@redhat.com

ADD *.rpm /tmp/origin-rpm/
RUN yum install -y /tmp/origin-rpm/*.rpm && \
    yum clean all && \
    curl https://storage.googleapis.com/golang/go$VERSION.linux-$(uname -m | sed 's/x86_64/amd64/g').tar.gz | tar -C /usr/local -xzf - && \
    go get golang.org/x/tools/cmd/cover \
        github.com/Masterminds/glide \
        golang.org/x/tools/cmd/goimports \
        github.com/tools/godep \
        golang.org/x/lint/golint \
        github.com/openshift/release/tools/gotest2junit \
        github.com/openshift/imagebuilder/cmd/imagebuilder && \
    mv $GOPATH/bin/* /usr/bin/ && \
    rm -rf $GOPATH/* $GOPATH/.cache && \
    mkdir $GOPATH/bin && \
    ln -s /usr/bin/imagebuilder $GOPATH/bin/imagebuilder && \
    ln -s /usr/bin/goimports $GOPATH/bin/goimports && \
    curl -L https://github.com/golang/dep/releases/download/v0.5.4/dep-linux-amd64 > /usr/bin/dep && \
    chmod +x /usr/bin/dep
    # TODO: symlink for backwards compatibility with hack/build-images.sh only, remove

RUN chmod g+xw -R $GOPATH && \
    chmod g+xw -R $(go env GOROOT)

WORKDIR /go/src/github.com/openshift/origin
LABEL io.k8s.display-name="OpenShift Origin Release Environment (golang-$VERSION)" \
      io.k8s.description="This is the standard release image for OpenShift Origin and contains the necessary build tools to build the platform."
