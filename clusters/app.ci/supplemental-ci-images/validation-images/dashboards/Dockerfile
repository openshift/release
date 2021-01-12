FROM registry.ci.openshift.org/openshift/release:golang-1.13

# Install jsonnet
RUN yum install -y yum-plugin-copr && yum copr enable paulfantom/jsonnet -y && \
      yum install -y jsonnet && yum clean all && rm -rf /var/cache/yum/*

# Install other required packages
RUN GOFLAGS="" GO111MODULE="on" go get github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb && \
      go get -u github.com/brancz/gojsontoyaml && \
      go get -u github.com/jteeuwen/go-bindata/... && \
      mkdir -p ${GOPATH}/src/github.com/openshift/release/

WORKDIR ${GOPATH}/src/github.com/openshift/release/
