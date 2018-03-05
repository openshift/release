#!/bin/bash

# Will be removed once we start developing upstream.

set -eux

# Clone PR
# Unfortunately go get is broken for acs-engine
# See https://github.com/Azure/acs-engine/issues/1160
go get github.com/Azure/acs-engine || true
cd /go/src/github.com/Azure/acs-engine
git remote set-url origin https://github.com/kargakis/acs-engine
git fetch origin pull/${PULL_NUMBER}/head
git checkout FETCH_HEAD

# Test
make test-style
make build-binary
make test