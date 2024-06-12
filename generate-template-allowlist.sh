#!/bin/bash

set -e

VOLUME_MOUNT_FLAGS=""
podman pull --platform linux/amd64 registry.ci.openshift.org/ci/template-deprecator:latest
podman run --platform linux/amd64 --rm --memory 4g -v /Users/weinliu/git_redhat2/release:/release registry.ci.openshift.org/ci/template-deprecator:latest --prow-jobs-dir /release/ci-operator/jobs --prow-config-path /release/core-services/prow/02_config/_config.yaml --plugin-config /release/core-services/prow/02_config/_plugins.yaml --allowlist-path /release/core-services/template-deprecation/_allowlist.yaml

