#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cd /go/src/github.com/openshift/hypershift/docs

# Install mkdocs and dependencies
pip3 install --user -r requirements.txt

# Build the documentation with strict mode
~/.local/bin/mkdocs build --strict

# Archive the built site for the next step
tar -czf "${SHARED_DIR}/docs-site.tar.gz" -C site .
echo "Documentation built successfully"
