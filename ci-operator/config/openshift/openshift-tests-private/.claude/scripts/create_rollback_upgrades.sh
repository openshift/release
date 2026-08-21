#!/bin/bash

set -e

TARGET_VERSION="$1"

cd ci-operator/config/openshift/openshift-tests-private

PRIOR_VERSION=$(.claude/scripts/get_prior_minor_version.sh "$TARGET_VERSION")

# Find all upgrade files for prior version
for file in openshift-openshift-tests-private-release-"$PRIOR_VERSION"__*-rollback-*.yaml; do

  # Create new filename (replace PRIOR_VERSION with TARGET_VERSION)
  new_file=$(echo "$file" | 
    sed "s/${PRIOR_VERSION}/${TARGET_VERSION}/g"
  )

  # Copy and update file content
  sed -e "s/\"${PRIOR_VERSION}\"/\"${TARGET_VERSION}\"/g" \
      -e "s/branch: release-${PRIOR_VERSION}/branch: release-${TARGET_VERSION}/g" \
      "$file" > "$new_file"

  # Update cron settings
  tools/update-cron-entries.py --backup no "$new_file"
  
  echo "$new_file"
done
