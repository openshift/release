#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Stop the harness dev server and copy Cypress artifacts.
harness_pid=""
function copyArtifacts {
  if [ -n "${harness_pid}" ]; then
    kill "${harness_pid}" 2>/dev/null || true
    pkill -f webpack.logging.config.ts 2>/dev/null || true
  fi
  for dir in screenshots videos; do
    if [ -d "/tmp/monitoring-plugin/web/cypress/${dir}/" ]; then
      cp -r "/tmp/monitoring-plugin/web/cypress/${dir}/" "${ARTIFACT_DIR}/${dir}"
      echo "${dir} copied successfully."
    else
      echo "Directory ${dir} does not exist. Nothing to copy."
    fi
  done
}

# Copy the artifacts to the artifact directory at the end of the test run.
trap copyArtifacts EXIT

export NO_COLOR=1
export CYPRESS_CACHE_FOLDER=/tmp/Cypress

# Install npm modules
cd /tmp/monitoring-plugin/web

# Skip revisions without the logging test harness (lands with the logging-view
# merge in monitoring-plugin) instead of failing the readiness check.
if [[ ! -f cypress.logging.config.ts ]] || ! grep -q '"start:logging-tests"' package.json; then
  echo "Skipping: logging test harness not present in this source revision."
  exit 0
fi

npm install

# Start the logging view test harness, a webpack dev server on localhost:9003.
npm run start:logging-tests &
harness_pid=$!

# Wait up to 5 minutes for the harness to accept connections.
for _ in $(seq 1 150); do (exec 3<>/dev/tcp/127.0.0.1/9003) 2>/dev/null && break; sleep 2; done
(exec 3<>/dev/tcp/127.0.0.1/9003) 2>/dev/null || {
  echo "ERROR: logging test harness did not become ready on port 9003"
  exit 1
}

# Run the Cypress tests
npx cypress run --config-file cypress.logging.config.ts --browser chrome --headless

# Stop the harness: kill the npm wrapper and the webpack dev server it
# spawned (npm does not reliably forward the signal to the child).
kill "${harness_pid}" 2>/dev/null || true
pkill -f webpack.logging.config.ts 2>/dev/null || true
harness_pid=""
