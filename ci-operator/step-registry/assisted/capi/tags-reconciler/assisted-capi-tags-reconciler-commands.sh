#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export GITHUB_APP_ID
export GITHUB_APP_INSTALLATION_ID
export GITHUB_APP_PRIVATE_KEY_PATH

pip install ruamel.yaml
python hack/tags_reconciler.py
