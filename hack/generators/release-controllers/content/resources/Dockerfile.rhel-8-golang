# Layers CI appropriate yum repository configurations on top of the ART builder images.
ARG MAJOR
ARG MINOR
FROM replaced-by-buildconfig

ENV VERSION=rhel-8-golang-openshift-${MAJOR}.${MINOR} \
    GOCACHE=/go/.cache \
    GOARM=5 \
    GOPATH=/go \
    GOROOT=/usr/local/go \
    GOFLAGS='-mod=vendor' \
    LOGNAME=deadbeef
ENV PATH=$PATH:$GOROOT/bin:$GOPATH/bin

# The repo files in the ART image will not work in CI. Remove them in preference of
# those appropriate for upstream dependencies.
# Also install epel for packages like tito.
RUN rm -rf /etc/yum.repos.d/*.repo && \
	curl http://base-${MAJOR}-${MINOR}-rhel8.ocp.svc > /etc/yum.repos.d/ci-rpm-mirrors.repo

LABEL io.k8s.display-name="OpenShift ${MAJOR}.${MINOR} RHEL-8 Golang Builder" \
      io.k8s.description="This is the standard golang builder for OpenShift ${MAJOR}.${MINOR} RHEL-8 images."
