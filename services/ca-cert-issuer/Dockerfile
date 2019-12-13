FROM registry.svc.ci.openshift.org/ocp/4.2:cli as builder

FROM centos:7

COPY --from=builder /usr/bin/oc /usr/bin/oc

RUN yum install -y cronie openssl git && \
      yum clean all && \
      rm -rf /var/cache/yum && \
      git clone https://github.com/Neilpang/acme.sh.git && \
      cd acme.sh && \
      mkdir /acme && \
      ./acme.sh --install --home /acme
