FROM binaries

RUN run.sh bash -c "echo '/cmd/cluster-capacity/go/src/github.com/kubernetes-incubator/cluster-capacity/_output' >> .gitignore" && \
    run.sh bash -c "echo '/cmd/service-catalog/go/src/github.com/kubernetes-incubator/service-catalog/_output' >> .gitignore" && \
    run.sh git add .gitignore && \
    run.sh git add -f _output/local/bin/linux/amd64 && \
    run.sh git add -f cmd/service-catalog/go/src/github.com/kubernetes-incubator/service-catalog/_output/local/bin/linux/amd64 && \
    run.sh git add -f cmd/cluster-capacity/go/src/github.com/kubernetes-incubator/cluster-capacity/_output/local/bin/linux/amd64 && \
    run.sh git commit -m "Add binaries"

RUN run.sh env RPM_BUILD_OPTS="--define 'skip_build 1'" make build-rpms
