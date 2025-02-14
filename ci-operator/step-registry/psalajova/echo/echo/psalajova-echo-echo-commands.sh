#!/bin/bash

echo "Pre-step executing: Preparing for dummy credential test."

SECRETS_DIR="/var/my-secrets"

if [[ -f "$SECRETS_DIR/psalajov-echo" ]]; then
  cat "$SECRETS_DIR/psalajov-echo"
else
  echo "Credential file missing." && exit 1
fi
