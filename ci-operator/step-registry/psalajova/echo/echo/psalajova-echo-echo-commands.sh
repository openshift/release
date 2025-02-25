#!/bin/bash

echo "Pre-step executing: Preparing for dummy credential test."

SECRETS_DIR="/var/my-secrets"

if [[ -f "$SECRETS_DIR/config" ]]; then
  cat "$SECRETS_DIR/config"
else
  echo "Credential file /var/my-secrets/config missing." && exit 1
fi
