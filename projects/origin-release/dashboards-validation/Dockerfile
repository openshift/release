FROM registry.svc.ci.openshift.org/openshift/release:golang-1.11

# Install required packages
RUN go get github.com/google/go-jsonnet/cmd/jsonnet; \
      go get github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb; \
      mkdir -p ${GOPATH}/src/github.com/openshift/release/

WORKDIR ${GOPATH}/src/github.com/openshift/release/
