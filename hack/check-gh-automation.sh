#!/bin/bash

# This script runs the check-gh-automation tool

set -o errexit
set -o nounset
set -o pipefail

echo "Running check-gh-automation"
echo
echo "This tool checks that our github automation has access to all repos with CI configured."
echo "If there is a failure, the steps at: https://docs.ci.openshift.org/docs/how-tos/onboarding-a-new-component/#granting-robots-privileges-and-installing-the-github-app"
echo "should be followed to add the necessary automation to the repo"
echo
echo "NOTE: if there is a 403 error in the collaborator check it is likely that the openshift-ci github app does not have access to the repo."
echo "Resolving this is also part of the process to onboard a repo to CI"
echo

exec check-gh-automation "$@"
