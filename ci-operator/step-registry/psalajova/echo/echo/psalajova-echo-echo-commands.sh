#!/bin/bash

echo "Psalajova pre-step executing: Preparing for dummy credential test."

SECRETS_DIR="/var/my-secrets"
for file in "$SECRETS_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Processing: $file"
    cat "$file"
  fi
done
