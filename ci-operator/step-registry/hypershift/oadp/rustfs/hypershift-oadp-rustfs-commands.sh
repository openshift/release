#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/packet-conf.sh"
rustfs_ip="$(<"${SHARED_DIR}/server-ip")"
access_key="rustfs"
secret_key="$(openssl rand -hex 24)"

env_file="$(mktemp)"
trap 'rm -f "${env_file}"' EXIT
printf 'RUSTFS_ACCESS_KEY=%s\nRUSTFS_SECRET_KEY=%s\n' \
  "${access_key}" "${secret_key}" > "${env_file}"
scp "${SSHOPTS[@]}" "${env_file}" "root@${IP}:/root/rustfs.env"

ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- "${rustfs_ip}" <<'HOST'
set -euo pipefail
rustfs_ip="$1"
trap 'rm -f /root/rustfs.env' EXIT
install -d -m 0700 /opt/rustfs/data /opt/rustfs/certs
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj "/CN=${rustfs_ip}" -addext "basicConstraints=critical,CA:FALSE" \
  -addext "subjectAltName=IP:${rustfs_ip},IP:127.0.0.1" \
  -keyout /opt/rustfs/certs/rustfs_key.pem -out /opt/rustfs/certs/rustfs_cert.pem >/dev/null 2>&1

# Podman gives the image's non-root user access to the data and certificate files.
podman run -d --replace --name rustfs -p 9000:9000 \
  --env-file /root/rustfs.env -e RUSTFS_TLS_PATH=/certs -e RUSTFS_CONSOLE_ENABLE=false \
  -v /opt/rustfs/data:/data:Z,U -v /opt/rustfs/certs:/certs:ro,Z,U \
  quay.io/rustfs/rustfs:1.0.7

if ! podman exec -i rustfs timeout 120 sh -eu <<'CLIENT'
endpoint="https://127.0.0.1:9000"
cert="/certs/rustfs_cert.pem"
until curl -fsS --max-time 5 --cacert "${cert}" "${endpoint}/health/ready" >/dev/null 2>&1; do
  sleep 2
done

HOME="$(mktemp -d)"
export HOME
trap 'rm -rf "${HOME}"' EXIT
rc alias set --ca-bundle "${cert}" --bucket-lookup path local "${endpoint}" \
  "${RUSTFS_ACCESS_KEY}" "${RUSTFS_SECRET_KEY}" >/dev/null
rc bucket create --ignore-existing local/oadp-backup
CLIENT
then
  echo "RustFS did not become ready or could not create the OADP bucket." >&2
  exit 1
fi

# The source guests use the libvirt network. The target cluster uses the host network.
firewall-cmd --zone=libvirt --add-port=9000/tcp
firewall-cmd --add-port=9000/tcp
HOST

# Both OADP setup steps read these filenames, including with different CI UIDs.
credentials="${SHARED_DIR}/minio-credentials"
install -m 0600 /dev/null "${credentials}"
printf '[default]\naws_access_key_id=%s\naws_secret_access_key=%s\n' \
  "${access_key}" "${secret_key}" > "${credentials}"
chgrp 0 "${credentials}"
chmod 640 "${credentials}"
printf 'https://%s:9000\n' "${rustfs_ip}" > "${SHARED_DIR}/minio-endpoint"
