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
echo
echo "NOTE: You can control how many job rehearsals are run:"
echo '- "/test pj-rehearse" runs up to 10 jobs (also run automatically on every PR push)'
echo '- "/test pj-rehearse-more" runs up to 20 jobs'
echo '- "/test pj-rehearse-max" runs up to 35 jobs'
echo
exec pj-rehearse "$@"
