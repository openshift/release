#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "## Install python dependencies"
python3 -m pip install --user --upgrade pip
python3 -m pip install poetry
poetry run python3 ms-integration-framework/ms_interop_framework_execution_framework.py
