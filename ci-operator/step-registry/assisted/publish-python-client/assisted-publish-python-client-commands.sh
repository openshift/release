#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

echo "************ assisted publish-python-client command ************"

TWINE_USERNAME=__token__ \
    TWINE_PASSWORD=$(cat /pypi-credentials/token) \
    make publish-client
