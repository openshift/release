#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Build kube-burner-ocp from fork with kube-apiserver pprof targets
FORK_REPO="https://github.com/redhat-chai-bot/kube-burner_kube-burner-ocp.git"
FORK_BRANCH="add-kube-apiserver-pprof-targets"
echo "Building kube-burner-ocp from ${FORK_REPO} branch ${FORK_BRANCH}..."

# Install Go (required for building kube-burner-ocp from source)
GO_VERSION="1.25.9"
curl -sL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
mkdir -p /tmp/goroot
tar -C /tmp/goroot -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
export GOROOT="/tmp/goroot/go"
export PATH="${GOROOT}/bin:${PATH}"
go version

# Clone the fork
KB_OCP_SRC=$(mktemp -d)
curl -sL "https://github.com/redhat-chai-bot/kube-burner_kube-burner-ocp/archive/refs/heads/add-kube-apiserver-pprof-targets.tar.gz" -o /tmp/kb-ocp.tar.gz
tar -xzf /tmp/kb-ocp.tar.gz --strip-components=1 -C "$KB_OCP_SRC"
rm /tmp/kb-ocp.tar.gz

# Build (direct go build — make is not available in CI container)
cd "$KB_OCP_SRC"
mkdir -p bin/amd64
GOARCH=amd64 CGO_ENABLED=0 go build -v -ldflags "-X github.com/cloud-bulldozer/go-commons/v2/version.Version=test" -o bin/amd64/kube-burner-ocp ./cmd/
cd -

# Verify the binary exists
ls -la "${KB_OCP_SRC}/bin/amd64/kube-burner-ocp"

echo "BUILD SUCCESS"
