#!/bin/bash
set -euo pipefail

echo "=== OpenShift API Review Eval ==="

mkdir -p "${HOME}/.claude"
touch "${HOME}/.claude/.claude.json"

CLONE_BRANCH="test-evals"

echo "Cloning openshift/api (branch: ${CLONE_BRANCH})..."
git clone --branch "${CLONE_BRANCH}" https://github.com/theobarberbany/api.git /tmp/api
cd /tmp/api

# Skip PR checkout when cloning from a fork — PR refs aren't available on fork remotes
if [ -n "${PULL_NUMBER:-}" ] && [[ "$(git remote get-url origin)" == *"openshift/api"* ]]; then
  echo "Checking out PR #${PULL_NUMBER}..."
  git fetch origin "pull/${PULL_NUMBER}/head:pr-${PULL_NUMBER}"
  git checkout "pr-${PULL_NUMBER}"
fi

echo "Running eval suite (EVAL_RUNS=${EVAL_RUNS}, EVAL_THRESHOLD=${EVAL_THRESHOLD})..."
cd tests && go run github.com/onsi/ginkgo/v2/ginkgo -v --tags=eval --timeout=1h --junit-report=junit-eval.xml ./eval/
