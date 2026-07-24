#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Temporary build-validation step: confirms Go install + fork tarball + go build
# works in the CI container before provisioning a cluster.
# Remove this step once confirmed working.

FORK_REPO="https://github.com/redhat-chai-bot/kube-burner_kube-burner-ocp"
FORK_BRANCH="add-kube-apiserver-pprof-targets"

# Install Go
GO_VERSION="1.25.9"
curl -sL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
mkdir -p /tmp/goroot
tar -C /tmp/goroot -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
export GOROOT=/tmp/goroot/go
export PATH="/tmp/goroot/go/bin:${PATH}"
go version

# Download fork source via tarball
KB_OCP_SRC=$(mktemp -d)
echo "Downloading ${FORK_REPO} branch ${FORK_BRANCH}..."
curl -sL "${FORK_REPO}/archive/refs/heads/${FORK_BRANCH}.tar.gz" -o /tmp/kb-ocp.tar.gz
tar -xzf /tmp/kb-ocp.tar.gz --strip-components=1 -C "$KB_OCP_SRC"
rm /tmp/kb-ocp.tar.gz

# Build
cd "$KB_OCP_SRC"
mkdir -p bin/amd64
GOARCH=amd64 CGO_ENABLED=0 go build -v -ldflags \
  "-X github.com/cloud-bulldozer/go-commons/v2/version.Version=test" \
  -o bin/amd64/kube-burner-ocp ./cmd/

# Verify
if [[ -f bin/amd64/kube-burner-ocp ]]; then
  echo "BUILD SUCCESS: $(ls -la bin/amd64/kube-burner-ocp)"
else
  echo "BUILD FAILED: binary not found"
  exit 1
fi
