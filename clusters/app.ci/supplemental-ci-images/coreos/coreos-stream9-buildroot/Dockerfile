# Image used for CoreOS CI that targets CentOS/RHEL9
FROM quay.io/centos/centos:stream9
COPY build-base.sh .
RUN ./build-base.sh
COPY build.sh .
RUN ./build.sh

LABEL io.k8s.display-name="CoreOS CentOS 9 Buildroot" \
      io.k8s.description="Used for CI for (RHEL) CoreOS related projects."
