#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

cd /tmp
curl -sSLO $RHDH_INSTALL_SCRIPT
chmod +x install-rhdh-catalog-source.sh

./install-rhdh-catalog-source.sh --install-operator rhdh