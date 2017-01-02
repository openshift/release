#!/bin/bash

set -euo pipefail

docker rm gce-pr &>/dev/null || true
docker create $@ --name gce-pr -it openshift/origin-gce:latest /bin/bash >/dev/null
tar -c -C data . | docker cp - gce-pr:/usr/share/ansible/openshift-ansible-gce/playbooks/files
docker start -ai gce-pr
