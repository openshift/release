FROM openshift/origin-base

ADD squid.repo /etc/yum.repos.d/squid.repo

RUN INSTALL_PKGS="squid squid-helpers" && \
    yum install -y $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    yum clean all && \
    rmdir /var/log/squid /var/spool/squid && \
    rm -f /etc/squid/squid.conf

ADD entrypoint.sh /tmp/entrypoint.sh

ENTRYPOINT /tmp/entrypoint.sh
