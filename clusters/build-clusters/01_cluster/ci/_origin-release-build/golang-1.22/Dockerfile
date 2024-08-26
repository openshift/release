#
# This is the image that controls the standard build environment for releasing OpenShift Origin.
# It is responsible for performing a cross platform build of OpenShift.
#
# The standard name for this image is openshift/origin-release
#
FROM quay.io/centos/centos:stream9

ENV VERSION=1.22.5 \
    GOCACHE=/go/.cache \
    GOPATH=/go \
    GOROOT=/usr/local/go \
    LOGNAME=deadbeef

ENV PATH=$PATH:$GOROOT/bin:$GOPATH/bin

RUN yum install -y epel-release epel-next-release && \
    rpm -V epel-release && \
    INSTALL_PKGS="bc bind-utils bsdtar device-mapper device-mapper-persistent-data e2fsprogs ethtool file findutils gcc git glib2-devel gpgme hostname jq krb5-devel libassuan libseccomp-devel lsof make mercurial nmap-ncat openssl rsync socat systemd-devel tar tito tree util-linux wget which xfsprogs zip" && \
    yum install -y $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    yum clean all && \
    touch /os-build-image && \
    git config --system user.name origin-release-container && \
    git config --system user.email origin-release@redhat.com

RUN \
    set -x &&  \
    curl --fail --retry 3 -L https://golang.org/dl/go$VERSION.linux-$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/').tar.gz | tar -C /usr/local -xzf - && \
    go install golang.org/x/tools/cmd/cover@latest && \
    go install golang.org/x/tools/cmd/goimports@latest && \
    go install golang.org/x/lint/golint@latest && \
    go install github.com/openshift/release/tools/gotest2junit@latest && \
    go install github.com/openshift/imagebuilder/cmd/imagebuilder@latest && \
    go install gotest.tools/gotestsum@latest && \
    mv $GOPATH/bin/* /usr/bin/ && \
    rm -rf $GOPATH/* $GOPATH/.cache && \
    mkdir $GOPATH/bin && \
    ln -s /usr/bin/imagebuilder $GOPATH/bin/imagebuilder && \
    ln -s /usr/bin/goimports $GOPATH/bin/goimports
    # TODO: symlink for backwards compatibility with hack/build-images.sh only, remove

RUN chmod g+xw -R $GOPATH && \
    chmod g+xw -R $(go env GOROOT)

WORKDIR /go/src/github.com/openshift/origin
LABEL io.k8s.display-name="OpenShift Origin Release Environment (golang-$VERSION)" \
      io.k8s.description="This is the standard release image for OpenShift Origin and contains the necessary build tools to build the platform."
