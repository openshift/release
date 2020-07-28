# Serves as a standard build environment for OpenShift builds. It is based on the
# ART golang builder and has packages layered on top of support CI only use cases
# (e.g. compiling test cases) that simply don't occur downstream.

# This FROM is published by ART as the golang builder used downstream (see ocp-build-data streams.yml)
FROM registry.svc.ci.openshift.org/ocp/builder:rhel-8-golang-1.14.art

ENV VERSION=1.14 \
    GOCACHE=/go/.cache \
    GOARM=5 \
    GOPATH=/go \
    GOROOT=/usr/local/go \
    GOFLAGS='-mod=vendor' \
    LOGNAME=deadbeef
ENV PATH=$PATH:$GOROOT/bin:$GOPATH/bin

# The repo files in the ART image will not work in CI. Remove them in preference of
# those appropriate for upstream dependencies. We grab the repos from one of the
# rpm mirrors specific to an openshift release, but the repos we expect to
# draw from are all Red Hat CDN repos & not OpenShift specific.
# Also install epel for packages like tito.
RUN rm -rf /etc/yum.repos.d/*.repo && \
	curl http://base-4-6-rhel8.ocp.svc > /etc/yum.repos.d/rpm-mirrors.repo && \
	yum install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm && \
    INSTALL_PKGS="bc procps-ng util-linux bind-utils bsdtar createrepo device-mapper device-mapper-persistent-data e2fsprogs ethtool file findutils gcc git glib2-devel gpgme gpgme-devel hostname iptables jq krb5-devel libassuan libassuan-devel libseccomp-devel libvirt-devel lsof make mercurial nmap-ncat openssl protobuf-compiler protobuf-devel rsync socat systemd-devel tar tito tree wget which xfsprogs zip goversioninfo" && \
    yum install -y $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    yum clean all && \
    touch /os-build-image && \
    git config --system user.name origin-release-container && \
    git config --system user.email origin-release@redhat.com

# Install common go tools upstream devs are expecting in CI.
RUN go get golang.org/x/tools/cmd/cover \
        github.com/Masterminds/glide \
        golang.org/x/tools/cmd/goimports \
        github.com/tools/godep \
        golang.org/x/lint/golint \
        gotest.tools/gotestsum \
        github.com/openshift/release/tools/gotest2junit \
        github.com/openshift/imagebuilder/cmd/imagebuilder && \
    GO111MODULE=on go get gotest.tools/gotestsum@v0.5.2 && \
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
LABEL io.k8s.display-name="OpenShift Origin Release RHEL8 Environment (golang-$VERSION)" \
      io.k8s.description="This is the standard release image for OpenShift Origin and contains the necessary build tools to build the platform."
