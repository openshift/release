#!/bin/bash

echo "Pre-step executing: This should list 1 file in my-secrets dir, and its content."

SECRETS_DIR="/var/my-secrets"
for file in "$SECRETS_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Secret content:"
    cat "$file"
    echo "--- End of secret content ---"
  fi
done

sleep 10m