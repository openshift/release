#!/usr/bin/env bash

set -x
short_sha=$(git rev-parse --short HEAD)
USER=netobserv VERSION=$short_sha make commands
export PATH=$PATH:$PWD/build
GINKGO_VERSION=$(go list -mod=readonly -m -f '{{ .Version }}'  github.com/onsi/ginkgo/v2)
export GINKGO_VERSION
# download the ginkgo cli binary
go install -mod=mod github.com/onsi/ginkgo/v2/ginkgo@$GINKGO_VERSION
ginkgo version
test -n "${KUBECONFIG:-}" && echo "${KUBECONFIG}" || echo "no KUBECONFIG is defined"
ginkgo --junit-report="${ARTIFACT_DIR}/junit/report.xml" e2e/integration-tests
