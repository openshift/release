#!/bin/bash

set -euo pipefail

ctr=gce-cluster
opts="--mode='ug+rwX' --owner=root --group=root"

docker rm $ctr &>/dev/null || true
docker create $@ --name $ctr -it openshift/origin-gce:latest /bin/bash >/dev/null
tar ${opts} -c -C data . | docker cp - $ctr:/usr/share/ansible/openshift-ansible-gce/playbooks/files
docker start -ai $ctr
