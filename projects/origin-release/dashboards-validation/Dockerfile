FROM docker.io/gcc:9.1.0 as builder

RUN cd /tmp/ && git clone --branch v0.12.1 https://github.com/google/jsonnet.git && \
      cd jsonnet && make

FROM registry.svc.ci.openshift.org/openshift/release:golang-1.11

# Install jsonnet
COPY --from=builder /tmp/jsonnet/jsonnet /usr/bin/
# Install required packages
RUN go get github.com/google/go-jsonnet/cmd/jsonnet; \
      go get github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb; \
      mkdir -p ${GOPATH}/src/github.com/openshift/release/

WORKDIR ${GOPATH}/src/github.com/openshift/release/
