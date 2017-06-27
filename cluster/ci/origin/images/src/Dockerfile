FROM release-base

ARG SOURCE_URL=https://github.com/openshift/origin.git
ARG PULL_REFS=""

RUN umask 0002 && release-ci cloneref "$SOURCE_URL"
