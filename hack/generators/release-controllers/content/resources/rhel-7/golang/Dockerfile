# Layers CI appropriate yum repository configurations on top of the ART builder images.
FROM replaced-by-buildconfig
ARG MAJOR
ARG MINOR

ENV VERSION=rhel-7-golang-openshift-${MAJOR}.${MINOR} \
    GOARM=5 \
    LOGNAME=deadbeef \
    GOCACHE=/go/.cache \
    GOPATH=/go \
    GOROOT=/usr/local/go \
    LOGNAME=deadbeef
ENV PATH=$PATH:$GOROOT/bin:$GOPATH/bin

# The repo files in the ART image will not work in CI. Remove them in preference of
# those appropriate for upstream dependencies.
# Also install epel for packages like tito.
RUN rm -rf /etc/yum.repos.d/*.repo && \
	curl http://base-${MAJOR}-${MINOR}.ocp.svc > /etc/yum.repos.d/rpm-mirrors.repo

# make go related directories writeable since builds in CI will run as non-root.
RUN mkdir -p $GOPATH $GOROOT && \
    chmod g+xw -R $GOPATH && \
    chmod g+xw -R $(go env GOROOT)

WORKDIR /go/src/github.com/openshift/origin

LABEL io.k8s.display-name="OpenShift ${MAJOR}.${MINOR} RHEL-7 Golang Builder" \
      io.k8s.description="This is the standard golang builder for OpenShift ${MAJOR}.${MINOR} RHEL-7 images."
