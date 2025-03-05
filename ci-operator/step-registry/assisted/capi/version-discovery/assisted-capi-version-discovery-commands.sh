#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

git config --global user.name "omer-vishlitzky"
git config --global user.email "ovishlit@redhat.com"

python scripts/discover_versions.py

git add release-candidates.yaml
git commit -m "Update release candidates"
git push origin HEAD:${PULL_BASE_REF}
