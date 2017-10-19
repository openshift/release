FROM release-ci:binary

ARG SOURCE_URL=https://github.com/openshift/origin.git

ENV GIT_COMMITTER_NAME=developer \
    GIT_COMMITTER_EMAIL=developer@redhat.com \
    OS_VERSION_FILE="" \
    PATH="${PATH}:/go/src/github.com/openshift/origin/_output/local/bin/linux/amd64" \
    HOME=/tmp \
    UMASK=0002

COPY run.sh /usr/bin/

RUN chmod g+xw -R /go && \
    chmod g+xw -R $(go env GOROOT) && \
    mkdir -p /tmp/openshift && chmod g+xw /tmp/openshift

RUN run.sh git clone "${SOURCE_URL}" . 

RUN run.sh env OS_ONLY_BUILD_PLATFORMS='linux/amd64' hack/build-cross.sh && \
    run.sh hack/build-go.sh vendor/github.com/onsi/ginkgo/ginkgo && \
    run.sh env OS_ONLY_BUILD_PLATFORMS='linux/amd64' GOPATH='' \
           cmd/service-catalog/go/src/github.com/kubernetes-incubator/service-catalog/hack/build-cross.sh && \
    run.sh env OS_ONLY_BUILD_PLATFORMS='linux/amd64' GOPATH='' \
           cmd/cluster-capacity/go/src/github.com/kubernetes-incubator/cluster-capacity/hack/build-cross.sh
