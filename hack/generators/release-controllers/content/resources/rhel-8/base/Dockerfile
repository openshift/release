# Layers CI appropriate yum repository configurations on top of the ART base images.
FROM replaced-by-buildconfig
ARG MAJOR
ARG MINOR

# The repo files in the ART image will not work in CI. Remove them in preference of
# those appropriate for upstream dependencies.
RUN rm -rf /etc/yum.repos.d/*.repo && \
	curl http://base-${MAJOR}-${MINOR}-rhel8.ocp.svc > /etc/yum.repos.d/ci-rpm-mirrors.repo

LABEL io.k8s.display-name="OpenShift ${MAJOR}.${MINOR} RHEL-8 Base Image" \
      io.k8s.description="This is the standard base image for OpenShift ${MAJOR}.${MINOR} RHEL-8 images."
