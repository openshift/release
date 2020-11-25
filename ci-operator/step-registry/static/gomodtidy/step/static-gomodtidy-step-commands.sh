#!/usr/bin/env bash

set -Eeuo pipefail

declare gosum
gosum="$(mktemp)"
readonly gosum
cp ./go.sum "$gosum"

# First test: `go mod tidy` exits cleanly
go mod tidy

# Second test: "go.sum" does not contain stale dependencies
diff ./go.sum "$gosum"
