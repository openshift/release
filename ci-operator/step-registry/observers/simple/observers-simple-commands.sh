#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

function cleanup() {
  while read pid
  do
    echo "killing child process $pid"
    kill $pid
  done < <(jobs -p)
  echo "ending gracefully"
}
trap cleanup SIGTERM

# $KUBECONFIG could not be available when the observer first starts
echo "waiting for $KUBECONFIG to exist"
while [ ! -s "$KUBECONFIG" ]
do
  sleep 1
done
echo 'kubeconfig received!'

# Do the actual work here
# ...

# ARTIFACT_DIR is still available, an observer is almost
# just like a regular test
printf "upload-me" >"${ARTIFACT_DIR}/simple-observer-artifact"

echo 'sleeping indefinitely'
sleep infinity &
wait $!