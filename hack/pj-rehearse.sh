#!/bin/bash

# This script runs the pj-rehearse tool

set -o errexit
set -o nounset
set -o pipefail

if echo "${JOB_SPEC}"|grep -q '"author":"openshift-bot"'; then
  echo "Pull request is created by openshift-bot, skipping rehearsal"
  exit 0
fi

echo "Running pj-rehearse"
exec pj-rehearse "$@"
