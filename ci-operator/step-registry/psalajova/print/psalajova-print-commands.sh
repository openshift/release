#!/bin/bash
echo "Print step executing."

SECRETS_DIR="/var/my-secrets"
for file in "$SECRETS_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Processing: $file"
  fi
done

SECRETS_DIR="/var/my-secrets-diff-mount-path"
for file in "$SECRETS_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Processing: $file"
  fi
done

sleep 10m