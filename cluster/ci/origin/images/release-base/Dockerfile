FROM openshift/origin-release:golang-1.8

ARG SOURCE_URL=https://github.com/openshift/origin.git

ENV GIT_COMMITTER_NAME=developer \
    GIT_COMMITTER_EMAIL=developer@redhat.com \
    OS_VERSION_FILE="" \
    PATH="${PATH}:/go/src/github.com/openshift/origin/_output/local/bin/linux/amd64" \
    HOME=/tmp

COPY release-ci /usr/bin/release-ci

RUN chmod g+xw -R /go && \
    chmod g+xw -R $(go env GOROOT) && \
    mkdir -p /tmp/openshift && chmod g+xw /tmp/openshift && \
    umask 0002 && \
    git clone "${SOURCE_URL}" . && \
    hack/build-go.sh
