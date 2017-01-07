#!/bin/bash

set -euo pipefail

ctr=gce-cluster

docker rm $ctr &>/dev/null || true
docker create $@ --name $ctr -it openshift/origin-gce:latest /bin/bash >/dev/null
tar --mode='ug+rwX' -c -C data . | docker cp - $ctr:/usr/share/ansible/openshift-ansible-gce/playbooks/files
docker start -ai $ctr
