#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/packet-conf.sh"
minio_ip="$(<"${SHARED_DIR}/server-ip")"
minio_dir="${SHARED_DIR}/minio-shared"
mkdir -p "${minio_dir}"
chmod 700 "${minio_dir}"

# The endpoint is reachable by both management clusters. Give this job its own
# credentials and use TLS because the target reaches the source host over the
# OFCIR host network rather than the source host's libvirt network.
minio_user="minio"
minio_password="$(openssl rand -hex 24)"
printf 'MINIO_ROOT_USER=%s\nMINIO_ROOT_PASSWORD=%s\n' \
  "${minio_user}" "${minio_password}" > "${minio_dir}/root.env"
printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' \
  "${minio_user}" "${minio_password}" > "${minio_dir}/credentials"
chmod 600 "${minio_dir}/root.env" "${minio_dir}/credentials"

scp "${SSHOPTS[@]}" "${minio_dir}/root.env" "root@${IP}:/root/minio-root.env"
ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${minio_ip}" <<'EOF'
set -euo pipefail
minio_ip="$1"
chmod 600 /root/minio-root.env
mkdir -p /opt/minio/data /opt/minio/certs
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj "/CN=${minio_ip}" -addext "subjectAltName=IP:${minio_ip}" \
  -keyout /opt/minio/certs/private.key -out /opt/minio/certs/public.crt >/dev/null 2>&1
podman network exists minio-net || podman network create minio-net
podman rm -f minio >/dev/null 2>&1 || true
podman run -d --name minio --network minio-net -p 9000:9000 \
  --env-file /root/minio-root.env \
  -v /opt/minio/data:/data:Z -v /opt/minio/certs:/root/.minio/certs:Z \
  quay.io/minio/minio server /data
set -a
source /root/minio-root.env
set +a
podman run --rm --network minio-net --env-file /root/minio-root.env \
  --entrypoint=/bin/sh quay.io/minio/mc -c \
  'mc --insecure alias set local https://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc --insecure mb local/oadp-backup'
firewall-cmd --zone=libvirt --add-port=9000/tcp
firewall-cmd --add-port=9000/tcp
EOF

printf 'https://%s:9000\n' "${minio_ip}" > "${SHARED_DIR}/minio-endpoint"
cp "${minio_dir}/credentials" "${SHARED_DIR}/minio-credentials"
# CI steps may run with different UIDs, but share the root group.
chgrp 0 "${SHARED_DIR}/minio-credentials"
chmod 640 "${SHARED_DIR}/minio-credentials"
