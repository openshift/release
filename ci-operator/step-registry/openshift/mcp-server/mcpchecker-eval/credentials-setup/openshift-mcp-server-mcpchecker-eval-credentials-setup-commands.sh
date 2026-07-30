#!/bin/bash
set -euo pipefail

# Disable tracing while handling credential values
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

cat >> "${SHARED_DIR}/mcpchecker-creds.env" <<EOF
export OPENAI_API_KEY=$(cat /var/run/openai-token/token)
EOF

$WAS_TRACING && set -x
