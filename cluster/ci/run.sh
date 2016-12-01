#!/bin/bash

set -euo pipefail

(
docker rm gce-bash || true
docker create --name gce-bash -it -e STARTUP_SCRIPT_FILE=/usr/local/install/data/startup.sh openshift/gce-cloud-installer:latest /bin/bash
docker cp data gce-bash:/usr/local/install
docker cp config.sh gce-bash:/usr/local/install/data/
) 1>&2
echo docker start -ai gce-bash
