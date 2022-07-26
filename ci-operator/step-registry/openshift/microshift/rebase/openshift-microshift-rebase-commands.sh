#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# Print context
echo "Environment:"
printenv

# Copy pull secret into place
cp /secrets/ci-pull-secret/.dockercfg "$HOME/.pull-secret.json" || {
    echo "ERROR: Could not copy registry secret file"
}

# Install yq (code borrowed from the ipi/install step-registry)
YQ_URL=https://github.com/mikefarah/yq/releases/download/v4.26.1/yq_linux_amd64
YQ_HASH=9e35b817e7cdc358c1fcd8498f3872db169c3303b61645cc1faf972990f37582
echo "${YQ_HASH} -" > /tmp/sum.txt
if ! curl -Ls "${YQ_URL}" | tee /tmp/yq | sha256sum -c /tmp/sum.txt >/dev/null 2>/dev/null; then
  echo "ERROR: Expected file at ${YQ_URL} to have checksum ${YQ_HASH} but instead got $(sha256sum </tmp/yq | cut -d' ' -f1)"
  strings /tmp/yq
  exit 1
fi
echo "Downloaded yq; sha256 checksum matches expected ${YQ_HASH}."
chmod +x /tmp/yq

# Determine pull specs for release images
release_amd64="$(oc get configmap/release-release-images-latest -o yaml \
    | /tmp/yq '.data."release-images-latest.yaml"' \
    | jq -r '.metadata.name')"
release_arm64="$(oc get configmap/release-release-images-arm64-latest -o yaml \
    | /tmp/yq '.data."release-images-arm64-latest.yaml"' \
    | jq -r '.metadata.name')"

pullspec_release_amd64="registry.ci.openshift.org/ocp/release:${release_amd64}"
pullspec_release_arm64="registry.ci.openshift.org/ocp-arm64/release-arm64:${release_arm64}"

echo "Pull spec for amd64 release image: ${pullspec_release_amd64}"
echo "Pull spec for arm64 release image: ${pullspec_release_arm64}"

# Call rebase script
echo "./scripts/rebase.sh to \"${pullspec_release_amd64}\" \"${pullspec_release_arm64}\""
./scripts/rebase.sh to "${pullspec_release_amd64}" "${pullspec_release_arm64}"
