#
# This is the image that controls the standard build environment for releasing OKD.
# It is responsible for performing a cross platform build of OKD.
#
# The standard name for this image is fedora-okd-builder
#
FROM fedora:30

ENV VERSION=1.12.10 \
    GOCACHE=/go/.cache \
    GOPATH=/go
ENV PATH=$PATH:$GOPATH/bin

RUN INSTALL_PKGS="bsdtar createrepo golang-$VERSION git krb5-devel make rpm-build rsync spectool systemd-devel" && \
    dnf install -y --setopt=skip_missing_names_on_install=False $INSTALL_PKGS && \
    dnf clean all && \
    touch /os-build-image && \
    git config --system user.name fedora-okd-builder-container && \
    git config --system user.email fedora-okd-builder@redhat.com

RUN go get golang.org/x/tools/cmd/cover \
        github.com/Masterminds/glide \
        golang.org/x/tools/cmd/goimports \
        github.com/tools/godep \
        golang.org/x/lint/golint \
        github.com/openshift/release/tools/gotest2junit

RUN mv $GOPATH/bin/* /usr/bin/ && \
    rm -rf $GOPATH/* $GOPATH/.cache && \
    mkdir $GOPATH/bin && \
    curl -L https://github.com/golang/dep/releases/download/v0.5.3/dep-linux-amd64 > /usr/bin/dep && \
    chmod +x /usr/bin/dep && \
    chmod g+xw -R $GOPATH && \
    chmod g+xw -R $(go env GOROOT)

WORKDIR /go/src/github.com/openshift/origin
LABEL io.k8s.display-name="Fedora OKD Build Environment (golang-$VERSION)" \
      io.k8s.description="This is the standard build environment for OKD-on-Fedora-CoreOS and contains the necessary tools to build the platform."
