# Layers CI appropriate yum repository configurations on top of the ART builder images.
FROM replaced-by-buildconfig
ARG MAJOR
ARG MINOR

ENV VERSION=rhel-8-golang-openshift-${MAJOR}.${MINOR} \
    GOARM=5 \
    LOGNAME=deadbeef \
    GOCACHE=/go/.cache \
    GOPATH=/go \
    LOGNAME=deadbeef
ENV PATH=$PATH:$GOPATH/bin
ENV OPENSHIFT_CI=true

# The repo files in the ART image will not work in CI. Remove them in preference of
# those appropriate for upstream dependencies.
# Also install epel for packages like tito.
RUN rm -rf /etc/yum.repos.d/*.repo && \
	curl http://base-${MAJOR}-${MINOR}-rhel8.ocp.svc > /etc/yum.repos.d/ci-rpm-mirrors.repo

# make go related directories writeable since builds in CI will run as non-root.
RUN mkdir -p $GOPATH && \
    chmod g+xw -R $GOPATH && \
    chmod g+xw -R $(go env GOROOT)

WORKDIR /go/src/github.com/openshift/origin

LABEL io.k8s.display-name="OpenShift ${MAJOR}.${MINOR} RHEL-8 Golang Builder" \
      io.k8s.description="This is the standard golang builder for OpenShift ${MAJOR}.${MINOR} RHEL-8 images."
