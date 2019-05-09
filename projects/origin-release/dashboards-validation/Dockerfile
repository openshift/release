FROM registry.svc.ci.openshift.org/openshift/release:golang-1.11

# Install jsonnet
RUN yum install -y centos-release-scl && yum install -y devtoolset-7-gcc*
# TODO: Use the following when https://github.com/containers/buildah/issues/1581 is fixed
# SHELL [ "/usr/bin/scl", "enable", "devtoolset-7" ]
RUN cd /tmp/ && git clone --branch v0.12.1 https://github.com/google/jsonnet.git && \
      cd jsonnet && scl enable devtoolset-7 -- make && cp jsonnet /usr/bin/

# Install other required packages
RUN go get -u github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb && \
      go get -u github.com/brancz/gojsontoyaml && \
      go get -u github.com/jteeuwen/go-bindata/... && \
      mkdir -p ${GOPATH}/src/github.com/openshift/release/

WORKDIR ${GOPATH}/src/github.com/openshift/release/
