FROM openshift/release:golang-1.8

COPY log-pods.sh /usr/bin/log-pods.sh

RUN mkdir -p /go/src/github.com/openshift && \
    cd /go/src/github.com/openshift && \
    git clone ${RELEASE_URL} release && \
    cd release && \
    git checkout ${RELEASE_REF} && \
    cd tools/release-ci && \
    go build . && \
    cp release-ci /usr/bin/release-ci
