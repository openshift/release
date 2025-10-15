#!/bin/bash
echo "Print test step executing."

SECRETS_DIR="/var/my-secrets"
for file in "$SECRETS_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Processing: $file"
    cat "$file"
  fi
done

SECRETS_DIR="/var/my-secrets2"
for file in "$SECRETS_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Processing: $file"
    cat "$file"
  fi
done
