FROM registry.svc.ci.openshift.org/openshift/release:golang-1.11

# Install jsonnet
RUN cd /tmp/ && git clone --branch v0.12.1 https://github.com/google/jsonnet.git && \
      cd jsonnet && make && cp jsonnet /usr/bin/

# Install other required packages
RUN go get -u github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb && \
      go get -u github.com/brancz/gojsontoyaml && \
      go get -u github.com/jteeuwen/go-bindata/... && \
      mkdir -p ${GOPATH}/src/github.com/openshift/release/

WORKDIR ${GOPATH}/src/github.com/openshift/release/

