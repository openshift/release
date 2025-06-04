#!/bin/bash

echo "Pre-step executing: Preparing for dummy credential test."

SECRETS_DIR="/var/my-secrets"

if [[ -f "$SECRETS_DIR/dummy-secret-w-metadata" ]]; then
  cat "$SECRETS_DIR/dummy-secret-w-metadata"
else
  echo "Credential file /var/my-secrets/dummy-secret-w-metadata missing." && exit 1
fi
