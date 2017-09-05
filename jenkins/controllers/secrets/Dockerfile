FROM openshift/origin:latest

USER root

RUN yum -y install epel-release && yum -y install python-pip && \
    pip install kubernetes jenkinsapi

RUN mkdir -p /home/user/bin && \
    chmod -R g+rwx /home/user

WORKDIR /home/user

ENV JENKINS_SERVICE_URL="http://jenkins" \
    HOME=/home/user \
    PATH=$PATH:/home/user/bin \
    JENKINS_TEMPLATE_NAME=jenkins-persistent

COPY bin/* /home/user/bin/

ENTRYPOINT ["/home/user/bin/run.sh"]
