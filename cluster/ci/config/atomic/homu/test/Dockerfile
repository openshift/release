FROM fedora:25
RUN yum -y install nss_wrapper git python-pip findutils && yum clean all && \
    mkdir /app && cd /app && git clone -b homu-rollup-2 https://github.com/cgwalters/homu.git && pip3 install ./homu && \
    find /usr/lib/python* -name git_helper.py -exec chmod a+x {} ';'
ADD ./nss-wrapper-exec /usr/bin/nss-wrapper-exec
ENV HOME=/tmp 
WORKDIR /tmp
EXPOSE 8080
CMD ["/usr/bin/nss-wrapper-exec", "env", "PYTHONUNBUFFERED=1", "/usr/bin/homu", "-v", "--config", "/etc/homu-secrets/cfg.toml"]
