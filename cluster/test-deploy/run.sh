#!/bin/bash

set -euo pipefail

(
docker rm gce-pr || true
docker create --name gce-pr -it openshift/origin-gce:latest /bin/bash
docker cp data gce-pr:/usr/local/install
) 1>&2
echo docker start -ai gce-pr
