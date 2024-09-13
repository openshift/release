#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

su -c '
#!/bin/bash
set -x

dnf install -y podman
podman pull quay.io/opendatahub/opendatahub-operator
' - newRoot
