FROM registry.ci.openshift.org/openshift/nodejs-16:latest
USER root
ENV PATH=$PATH:/opt/rh/nodejs-16/root/usr/bin
RUN mkdir -p /go
RUN chmod g+xw -R /go