#!/usr/bin/env bash
set -euo pipefail

# Start port-forward using oc (has cluster-admin access) to avoid RBAC issues
oc port-forward -n obs-mcp svc/obs-mcp 9100:9100 &
PF_PID=$!
sleep 3

# Set OBS_MCP_URL so tests use this port-forward instead of creating their own
export OBS_MCP_URL=http://localhost:9100

# Run tests
make test-e2e
TEST_EXIT=$?

# Stop port-forward using saved PID
kill $PF_PID 2>/dev/null || true
sleep 1

# Verify port-forward is stopped, force kill if still running
if kill -0 $PF_PID 2>/dev/null; then
  echo "Port-forward still running, force killing..."
  kill -9 $PF_PID 2>/dev/null || true
fi

exit $TEST_EXIT
