#!/bin/bash
echo "Test-step executing."

SECRETS_DIR="/var/my-secrets"
for file in "$SECRETS_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Processing: $file"
  fi
done

SECRETS_DIR="/var/my-secrets2"
for file in "$SECRETS_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Processing: $file"
  fi
done

sleep 10m