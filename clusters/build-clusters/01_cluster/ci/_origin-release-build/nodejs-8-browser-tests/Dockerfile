FROM openshift/nodejs:20-ubi9
USER root
RUN microdnf install -y java-11-openjdk \
                        java-11-openjdk-headless \
                        xorg-x11-server-Xvfb \
                        firefox \
                        xorg-x11-utils && \
    microdnf clean all && \
    dbus-uuidgen > /etc/machine-id