#!/bin/bash

set -e

TARGET_VERSION="$1"


PRIOR_VERSION=$(.claude/scripts/get_prior_minor_version.sh "$TARGET_VERSION")
Y_PRIOR_VERSION=$(.claude/scripts/get_prior_minor_version.sh "$PRIOR_VERSION")

# Find all upgrade files for prior version
for file in openshift-openshift-tests-private-release-"$PRIOR_VERSION"__*-"$PRIOR_VERSION"-upgrade-from-stable-*.yaml; do
  # Get the initial version for Y stream and Z stream upgrade configuration files
  if echo "$file" | grep "${PRIOR_VERSION}.yaml" > /dev/null; then
    initial_version=${PRIOR_VERSION}
  elif echo "$file" | grep "${Y_PRIOR_VERSION}.yaml" > /dev/null; then
    initial_version=${Y_PRIOR_VERSION}
  else
    continue
  fi

  # Extract the initial version from filename (e.g., 4.20, 4.21)
  initial_major=$(echo "$initial_version" | cut -d. -f1)
  initial_minor=$(echo "$initial_version" | cut -d. -f2)

  # Calculate new initial version (add 1 to minor)
  new_initial_minor=$((initial_minor + 1))
  new_initial_version="${initial_major}.${new_initial_minor}"

  # Create new filename (replace 4.21 with 4.22, and initial version with new initial version)
  new_file=$(echo "$file" | 
    sed "s/release-${PRIOR_VERSION}/release-${TARGET_VERSION}/g" | 
    sed "s/-${PRIOR_VERSION}-upgrade/-${TARGET_VERSION}-upgrade/g" | 
    sed "s/stable-${initial_version}/stable-${new_initial_version}/g"
  )

  # Extract architecture/stream from original filename
  arch_stream=$(echo "$file" | sed "s/.*__\(.*\)-${PRIOR_VERSION}-upgrade-from-stable-.*/\1/")

  # Copy and update file content
  sed -e "s/\"${PRIOR_VERSION}\"/\"${TARGET_VERSION}\"/g" \
      -e "s/\"${initial_version}\"/\"${new_initial_version}\"/g" \
      -e "s/branch: release-${PRIOR_VERSION}/branch: release-${TARGET_VERSION}/g" \
      -e "s/variant: .*-${PRIOR_VERSION}-upgrade-from-stable-${initial_version}/variant: ${arch_stream}-${TARGET_VERSION}-upgrade-from-stable-${new_initial_version}/g" \
      "$file" > "$new_file"

  # Update cron settings
  tools/update-cron-entries.py --backup no "$new_file"
  
  echo "$new_file"
done
