#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ config minio command ************"

source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << 'EOF' |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'
set -x
mkdir -p /opt/minio/data
podman network create minio-net
podman run -d --name minio --network minio-net -p 9000:9000 -p 9001:9001 -v /opt/minio/data:/data -e "MINIO_ROOT_USER=admin" -e "MINIO_ROOT_PASSWORD=admin123" quay.io/minio/minio server /data --console-address ":9001"
podman run -it --entrypoint=/bin/sh --network minio-net quay.io/minio/mc \
  -c 'mc alias set myminio http://minio:9000 admin admin123 --api s3v4 && mc mb myminio/oadp-backup'

echo "update firewall"
sudo firewall-cmd --permanent --zone=libvirt --add-port=9000/tcp
sudo firewall-cmd --permanent --zone=libvirt --add-port=9001/tcp
sudo firewall-cmd --reload
EOF
