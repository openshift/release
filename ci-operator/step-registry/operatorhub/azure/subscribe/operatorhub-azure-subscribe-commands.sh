#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


echo "Installing ${PACKAGE} from ${CHANNEL} into ${INSTALL_NAMESPACE}, targeting ${TARGET_NAMESPACES}"

# TODO
