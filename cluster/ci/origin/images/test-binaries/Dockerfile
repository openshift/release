FROM source

ENV UMASK=0002

RUN run.sh env OS_GOFLAGS="-race" hack/build-go.sh
