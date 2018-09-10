# This Dockerfile is used to create origin-release:bazel necessary to build
# openshift/installer smoke tests.

FROM docker.io/openshift/origin-release:golang-1.10

RUN wget -P /etc/yum.repos.d https://copr.fedorainfracloud.org/coprs/vbatts/bazel/repo/epel-7/vbatts-bazel-epel-7.repo

RUN yum install -y bazel gcc-c++ libtool && \
    yum clean all

WORKDIR /go/src/github.com/openshift/origin
