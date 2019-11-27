FROM registry.svc.ci.openshift.org/ocp/4.2:cli as builder

FROM centos:7

COPY --from=builder /usr/bin/oc /usr/bin/oc

RUN yum install -y cronie openssl && \
      yum clean all && \
      rm -rf /var/cache/yum && \
      curl https://get.acme.sh | sh
