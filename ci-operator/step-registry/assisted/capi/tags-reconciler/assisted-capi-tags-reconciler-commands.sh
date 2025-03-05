#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

pip install ruamel.yaml
python hack/tags_reconciler.py
