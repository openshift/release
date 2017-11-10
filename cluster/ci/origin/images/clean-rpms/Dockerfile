FROM build-base

ARG PULL_REFS=master
ARG REPO_OWNER=openshift
ARG REPO_NAME=origin

ENV UMASK=0002

RUN run.sh release-ci cloneref --src-root=/data && \
    run.sh bash -c "echo '/cmd/cluster-capacity/go/src/github.com/kubernetes-incubator/cluster-capacity/_output' >> .gitignore" && \
    run.sh bash -c "echo '/cmd/service-catalog/go/src/github.com/kubernetes-incubator/service-catalog/_output' >> .gitignore" && \
    run.sh git add .gitignore && \
    run.sh git commit -m "Modify .gitignore"

RUN run.sh make build-rpms
