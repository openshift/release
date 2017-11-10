FROM build-base

ARG PULL_REFS=master
ARG REPO_OWNER=openshift
ARG REPO_NAME=origin

ENV UMASK=0002

RUN run.sh release-ci cloneref --src-root=/data

RUN run.sh env OS_ONLY_BUILD_PLATFORMS='linux/amd64' hack/build-cross.sh && \
    run.sh env OS_ONLY_BUILD_PLATFORMS='linux/amd64' GOPATH='' \
           cmd/service-catalog/go/src/github.com/kubernetes-incubator/service-catalog/hack/build-cross.sh && \
    run.sh env OS_ONLY_BUILD_PLATFORMS='linux/amd64' GOPATH='' \
           cmd/cluster-capacity/go/src/github.com/kubernetes-incubator/cluster-capacity/hack/build-cross.sh
