#!/bin/bash

echo "Pre-step executing: This should list 1 file in my-secrets dir."

SECRETS_DIR="/var/my-secrets"
for file in "$SECRETS_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Processing: $file"
  fi
done

sleep 30m