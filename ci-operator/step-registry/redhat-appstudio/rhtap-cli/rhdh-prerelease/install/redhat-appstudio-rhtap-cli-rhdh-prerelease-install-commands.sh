#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

cd /tmp
curl -sSLO $RHDH_INSTALL_SCRIPT
chmod +x install-rhdh-catalog-source.sh

# Comment out lines to apply subscription as the rhtap-cli will do this.
sed -i.bak '/# Create OperatorGroup/,$ s/^/#/' install-rhdh-catalog-source.sh

./install-rhdh-catalog-source.sh --next --install-operator rhdh