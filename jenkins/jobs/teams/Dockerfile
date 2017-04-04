FROM openshift/origin:latest

USER root

RUN yum -y install epel-release
RUN yum -y install python-pip git

RUN pip install --upgrade pip setuptools
RUN pip install kubernetes github3.py
RUN pip install git+https://github.com/openshift/openshift-restclient-python.git

RUN mkdir -p /home/user/bin && \
    chmod -R g+rwx /home/user

WORKDIR /home/user

ENV HOME=/home/user \
    PATH=$PATH:/home/user/bin

COPY bin/* /home/user/bin/

ENTRYPOINT ["/home/user/bin/sync-groups.py", "/var/run/secrets/github.io/oauth-token", "/var/run/config/sync-spec"]