#!/bin/bash

echo "1) This should list 1 file in my-secrets dir, and its content."

SECRETS_DIR="/var/my-secrets"
for file in "$SECRETS_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Secret content:"
    cat "$file"
    echo "--- End of secret content ---"
  fi
done

echo "2) This should list 1 file in my-secrets-diff-mount-path dir, and its content."

SECRETS_DIR="/var/my-secrets-diff-mount-path"
for file in "$SECRETS_DIR"/*; do
  if [ -f "$file" ]; then
    echo "Secret content:"
    cat "$file"
    echo "--- End of secret content ---"
  fi
done

sleep 10m