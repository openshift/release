FROM quay.io/deis/go-dev:v1.9.1

RUN apt-get update && \
    wget https://github.com/openshift/origin/releases/download/v3.10.0-rc.0/openshift-origin-client-tools-v3.10.0-rc.0-c20e215-linux-64bit.tar.gz && \
    tar -xzf openshift-origin-client-tools-v3.10.0-rc.0-c20e215-linux-64bit.tar.gz && \
    cp ./openshift-origin-client-tools-v3.10.0-rc.0-c20e215-linux-64bit/oc /usr/local/bin/ && \
    rm -rf openshift-origin-client-tools-v3.10.0-rc.0-c20e215-linux-64bit.tar.gz openshift-origin-client-tools-v3.10.0-rc.0-c20e215-linux-64bit