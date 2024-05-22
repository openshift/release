#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

cv="$CALICO_VERSION"
#OLM_VER_WHOLE="$CALICO_OLM_VERSION"
#OLM_VER_CHANNEL="$CALICO_OLM_CHANNEL"

sed -i "s/networkType: .*/networkType: Calico/" "${SHARED_DIR}/install-config.yaml"



OLM_URL="https://github.com/projectcalico/calico/releases/download/v${cv}/ocp.tgz"

curl --silent --location --fail --show-error "${OLM_URL}" --output /tmp/calico-ocp.tgz
tar -C /tmp -xf /tmp/calico-ocp.tgz

# the tar file from tigera is called ocp when uncompressed
pushd /tmp/ocp
sed -i 's/docker/quay/' 02-tigera-operator.yaml
for manifest in *.yaml ; do
  cp "${manifest}" "${SHARED_DIR}/manifest_${manifest}"
done

