#!/bin/bash
set -euo pipefail

# Disable tracing while handling credential values
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

TOKEN_PATH="/var/run/ocp-mcp/openai-token"

# Show mount contents without printing secret values.
echo "ocp-mcp credential mount:"
ls -la /var/run/ocp-mcp

echo "openai-token path checks:"
echo "  exists (-e): $([[ -e "${TOKEN_PATH}" ]] && echo yes || echo no)"
echo "  symlink (-L): $([[ -L "${TOKEN_PATH}" ]] && echo yes || echo no)"
echo "  regular file (-f): $([[ -f "${TOKEN_PATH}" ]] && echo yes || echo no)"
echo "  readable (-r): $([[ -r "${TOKEN_PATH}" ]] && echo yes || echo no)"
# Follow symlink to show target mode/owner without dumping contents.
ls -lL "${TOKEN_PATH}" || echo "  ls -lL failed: $?"
stat -c "  stat: mode=%a uid=%u gid=%g size=%s" "${TOKEN_PATH}" 2>/dev/null \
  || stat -f "  stat: mode=%Lp uid=%u gid=%g size=%z" "${TOKEN_PATH}" 2>/dev/null \
  || echo "  stat failed: $?"

if [[ ! -e "${TOKEN_PATH}" ]]; then
    echo "ERROR: ${TOKEN_PATH} does not exist in ocp-mcp secret mount" >&2
    exit 1
fi
if [[ ! -r "${TOKEN_PATH}" ]]; then
    echo "ERROR: ${TOKEN_PATH} exists but is not readable by $(id -u):$(id -g) ($(id))" >&2
    exit 1
fi

echo "Reading openai-token (byte length only)..."
TOKEN="$(cat "${TOKEN_PATH}")" || {
    echo "ERROR: cat ${TOKEN_PATH} failed with exit $?" >&2
    exit 1
}
TOKEN_LEN="${#TOKEN}"
echo "openai-token bytes: ${TOKEN_LEN}"
if [[ "${TOKEN_LEN}" -eq 0 ]]; then
    echo "ERROR: ${TOKEN_PATH} is empty" >&2
    exit 1
fi

echo "Writing OPENAI_API_KEY to ${SHARED_DIR}/mcpchecker-creds.env"
# %q avoids breaking the env file on special characters; never echo TOKEN.
printf 'export OPENAI_API_KEY=%q\n' "${TOKEN}" >> "${SHARED_DIR}/mcpchecker-creds.env"
echo "credentials-setup completed successfully"

if [[ "${WAS_TRACING}" == true ]]; then
    set -x
fi
