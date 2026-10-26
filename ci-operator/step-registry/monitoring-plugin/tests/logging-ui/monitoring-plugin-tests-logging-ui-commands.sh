#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# The logging UI test harness lives in the monitoring-plugin repository so it can
# change with the plugin version; this step only dispatches to `make test-logging-ui`.
if ! grep -q '^test-logging-ui:' /tmp/monitoring-plugin/Makefile 2>/dev/null; then
  echo "Skipping: test-logging-ui target not present in this source revision."
  exit 0
fi

make -C /tmp/monitoring-plugin test-logging-ui
