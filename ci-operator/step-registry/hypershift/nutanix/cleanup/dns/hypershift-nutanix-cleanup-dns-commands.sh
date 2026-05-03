#!/bin/bash

set -o nounset
set -o pipefail
# Don't set -e, we want to try cleanup even if some steps fail

echo "************ Cleanup DNS for HyperShift Hosted Cluster on Nutanix ************"

# AWS Route 53 credentials
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/nutanix-dns/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

# Check if delete batch exists
if [ ! -f "${SHARED_DIR}/hosted-dns-delete.json" ]; then
    echo "$(date -u --rfc-3339=seconds) - No DNS delete batch found, skipping cleanup"
    exit 0
fi

# Check if hosted zone ID exists
if [ ! -f "${SHARED_DIR}/hosted-zone.txt" ]; then
    echo "$(date -u --rfc-3339=seconds) - No hosted zone ID found, skipping cleanup"
    exit 0
fi

# Install AWS CLI if not available
if ! command -v aws &> /dev/null; then
    echo "$(date -u --rfc-3339=seconds) - Installing AWS CLI..."
    export PATH="${HOME}/.local/bin:${PATH}"

    if [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 3 ]; then
        python -m ensurepip
        if command -v pip3 &> /dev/null; then
            pip3 install --user awscli
        elif command -v pip &> /dev/null; then
            pip install --user awscli
        fi
    fi
fi

HOSTED_ZONE_ID=$(cat "${SHARED_DIR}/hosted-zone.txt")

echo "$(date -u --rfc-3339=seconds) - Deleting DNS records from hosted zone: ${HOSTED_ZONE_ID}"
echo "$(date -u --rfc-3339=seconds) - Delete batch:"
cat "${SHARED_DIR}/hosted-dns-delete.json"

# Delete DNS records
if CHANGE_ID=$(aws route53 change-resource-record-sets \
    --hosted-zone-id "${HOSTED_ZONE_ID}" \
    --change-batch file:///"${SHARED_DIR}"/hosted-dns-delete.json \
    --query '"ChangeInfo"."Id"' \
    --output text 2>&1); then

    echo "$(date -u --rfc-3339=seconds) - Delete initiated, Change ID: ${CHANGE_ID}"

    # Wait for deletion to complete
    if aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}"; then
        echo "$(date -u --rfc-3339=seconds) - DNS records deleted successfully"
    else
        echo "$(date -u --rfc-3339=seconds) - WARNING: Timeout waiting for DNS deletion"
    fi
else
    echo "$(date -u --rfc-3339=seconds) - WARNING: Failed to delete DNS records"
    echo "${CHANGE_ID}"
fi

echo "$(date -u --rfc-3339=seconds) - DNS cleanup completed"
