FROM source

RUN /bin/bash -c "make build-rpms"

CMD cd /go/src/github.com/openshift/origin/_output/local/releases/rpms && \
    python -m SimpleHTTPServer 8080

EXPOSE 8080
