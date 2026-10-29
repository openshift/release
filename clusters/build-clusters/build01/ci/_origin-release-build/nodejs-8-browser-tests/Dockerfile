FROM openshift/origin-release:nodejs-8
USER root
RUN yum install -y java-1.?.0-openjdk Xvfb firefox xorg-x11-utils && \
    yum clean all -y  && \
    dbus-uuidgen > /etc/machine-id