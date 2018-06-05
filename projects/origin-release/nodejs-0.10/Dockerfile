FROM openshift/origin-release:golang-1.10

FROM openshift/nodejs-010-centos7
COPY --from=0 /usr/bin/clonerefs /usr/bin/clonerefs
USER root
RUN yum install -y make && \
    yum clean all && \
    mkdir -p /go && \
    chmod g+xw -R /go
