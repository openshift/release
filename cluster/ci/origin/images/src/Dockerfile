FROM release-base

ARG REPO_OWNER
ARG REPO_NAME
ARG PULL_REFS

RUN umask 0002 && release-ci cloneref --src-root=/data
