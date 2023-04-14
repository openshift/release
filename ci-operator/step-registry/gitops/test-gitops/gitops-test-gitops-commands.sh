#!/usr/bin/env bash
set -o pipefail

# Check that the container is already logged into OCP:
oc whoami || {
  echo "ERROR: Not logged in OCP cluster. Please, login prior to run this script"
  exit 1
}

# Clone Operator-E2E suite:
git clone https://gitlab.cee.redhat.com/gitops/operator-e2e /opt/operator-e2e || {
  echo "ERROR: Unable to clone operator-e2e repository"
  exit 2
}

# Run Kuttl test suite
{
  make -C /opt/operator-e2e/gitops-operator e2e-tests \&&
  echo "Tests ran successfully"
  exit 0
} || {
  echo "ERROR: Test execution failed"
  exit 3
}
