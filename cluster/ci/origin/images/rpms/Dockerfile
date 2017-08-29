FROM source

RUN /bin/bash -c "OS_ONLY_BUILD_PLATFORMS='linux/amd64' SKIP_TEARDOWN=1 hack/build-rpm-release.sh"

CMD cd /go/src/github.com/openshift/origin/_output/local/releases/rpms && \
    python -m SimpleHTTPServer 8080

EXPOSE 8080
