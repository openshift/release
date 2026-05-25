#!/bin/sh 

# Used on periodic-image-mirroring-*
 
set -o errexit 
 
if [ -z ${MAPPING_FILE_PREFIX} ]; then >&2 echo "MAPPING_FILE_PREFIX is unset or empty" && exit 1; else echo "MAPPING_FILE_PREFIX is set to $MAPPING_FILE_PREFIX"; fi 
 
dry_run="${dry_run:-true}" 
cp ~/.docker/config.json /tmp/config.json 
oc registry login --to /tmp/config.json 

# QCI proxy authenticates any SA that belongs to the build farm
if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
  t="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
  oc registry login --to=/tmp/config.json --auth-basic="default:${t}" --registry=quay-proxy.ci.openshift.org
fi

failures=0 
for mapping in /etc/imagemirror/${MAPPING_FILE_PREFIX}*; do 
  echo "Running: oc image mirror --dry-run=${dry_run} --keep-manifest-list -f=$mapping --skip-multiple-scopes" 
  if ! oc image mirror --dry-run=${dry_run} --keep-manifest-list -a /tmp/config.json -f="$mapping" --skip-multiple-scopes; then 
    echo "ERROR: Failed to mirror images from $mapping" 
    failures=$((failures+1)) 
  fi 
done 
 
echo "finished" 
exit $failures
