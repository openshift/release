#!/bin/bash
set -e
set -o pipefail

export JIRA_TOKEN=/var/jira-token/token
export Z_STREAM_VERSION=$VERSION

echo "Content of shared_dir is: $(ls -la $SHARED_DIR)"

echo "Running Z stream issue clone - $Z_STREAM_VERSION"

cd /eco-ci-cd/scripts
python3 clone-z-stream-issue.py

