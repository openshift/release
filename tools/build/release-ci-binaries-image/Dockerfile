FROM openshift/release:golang-1.8

COPY log-pods.sh /usr/bin/log-pods.sh

RUN mkdir -p /go/src/github.com/openshift && \
    cd /go/src/github.com/openshift && \
    git clone ${RELEASE_URL} release && \
    cd release && \
    git checkout ${RELEASE_REF} && \
    cd tools/release-ci && \
    CGO_ENABLED=0 GOOS=linux go build -a --ldflags '-extldflags "-static"' . && \
    cp release-ci /usr/bin/release-ci
