#!/bin/bash
set -euo pipefail

if [[ ! -s "${SHARED_DIR}/terraform-georep-storage.tgz" ]]; then
    echo "No geo-rep storage state found in SHARED_DIR; skipping cleanup." >&2
    exit 0
fi

QUAY_AWS_ACCESS_KEY="$(cat /var/run/quay-qe-aws-secret/access_key)"
QUAY_AWS_SECRET_KEY="$(cat /var/run/quay-qe-aws-secret/secret_key)"
export AWS_ACCESS_KEY_ID="${QUAY_AWS_ACCESS_KEY}"
export AWS_SECRET_ACCESS_KEY="${QUAY_AWS_SECRET_KEY}"

WORKDIR="$(mktemp -d)"
cd "${WORKDIR}"
cp "${SHARED_DIR}/terraform-georep-storage.tgz" .
tar -xzf terraform-georep-storage.tgz

BUCKET_PRIMARY="$(cat "${SHARED_DIR}/QUAY_GEOREP_S3_BUCKET_PRIMARY" 2>/dev/null || true)"
BUCKET_SECONDARY="$(cat "${SHARED_DIR}/QUAY_GEOREP_S3_BUCKET_SECONDARY" 2>/dev/null || true)"
echo "Destroying geo-rep S3 buckets: primary=${BUCKET_PRIMARY:-unknown} secondary=${BUCKET_SECONDARY:-unknown}" >&2

terraform init
destroy_rc=1
for attempt in 1 2 3; do
    echo "terraform destroy attempt ${attempt}/3 ..." >&2
    destroy_rc=0
    terraform destroy -auto-approve || destroy_rc=$?
    [[ "${destroy_rc}" -eq 0 ]] && break
    echo "terraform destroy attempt ${attempt} failed (rc=${destroy_rc})" >&2
    sleep 10
done
if [[ "${destroy_rc}" -ne 0 ]]; then
    echo "WARNING: geo-rep storage terraform destroy failed after 3 attempts (rc=${destroy_rc}). Resources may be leaked." >&2
fi
