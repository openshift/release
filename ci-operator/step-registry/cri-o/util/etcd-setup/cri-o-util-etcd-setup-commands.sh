#!/bin/bash
set -o nounset
set -o errexit
set -xeuo pipefail

echo "checking etcd version"

latest=$(wget -q -O- https://api.github.com/repos/coreos/etcd/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if gcloud ls gs://crio-ci | grep -q ${latest} ; then 
    echo "etcd is up to date"
else 
    echo "caching etcd" 
    curl https://github.com/coreos/etcd/releases/download/${latest}/etcd-${latest}-linux-amd64.tar.gz -L | gsutil cp - gs://crio-ci/etcd-${latest}.tar.gz
fi
