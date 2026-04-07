#!/bin/bash

set -e

TARGET_VERSION="$1"

MINOR=$(echo "$TARGET_VERSION" | cut -d. -f2)

if [[ $((MINOR % 2)) -eq 0 ]]; then
  echo "$TARGET_VERSION is even-numbered version, continue";
else
  echo "$TARGET_VERSION is odd-numbered, stop creating CPOU upgrade jobs";
  exit 1
fi

cd ci-operator/config/openshift/openshift-tests-private

# NEW_INTERMEDIATE, e.g. 4.19
NEW_INTERMEDIATE=$(.claude/scripts/get_prior_minor_version.sh "$TARGET_VERSION") 
# NEW_INIT_VERSION is last CPOU job's target version which is also the new initial version, e.g. 4.18, and 
NEW_INIT_VERSION=$(.claude/scripts/get_prior_minor_version.sh "$NEW_INTERMEDIATE")
# OLD_INTERMEDIATE, e.g. 4.17
OLD_INTERMEDIATE=$(.claude/scripts/get_prior_minor_version.sh "$NEW_INIT_VERSION") 
# OLD_INIT_VERSION, e.g. 4.16
OLD_INIT_VERSION=$(.claude/scripts/get_prior_minor_version.sh "$OLD_INTERMEDIATE")



# Find all upgrade files for last CPOU upgrade
for file in openshift-openshift-tests-private-release-"$NEW_INIT_VERSION"__*-*-"$NEW_INIT_VERSION"-cpou-upgrade-from-"$OLD_INIT_VERSION".yaml; do

  # Create new filename (replace PRIOR_VERSION with TARGET_VERSION)
  new_file=$(echo "$file" | 
    sed "s/${NEW_INIT_VERSION}/${TARGET_VERSION}/g" |
    sed "s/${OLD_INIT_VERSION}/${NEW_INIT_VERSION}/g"
  )

  arch_stream=$(echo "$file" | sed "s/.*__\(.*\)-${NEW_INIT_VERSION}-cpou-upgrade-from-.*/\1/")
  # Copy and update file content
  sed -e "s/\"${NEW_INIT_VERSION}\"/\"${TARGET_VERSION}\"/g" \
      -e "s/\"${OLD_INTERMEDIATE}\"/\"${NEW_INTERMEDIATE}\"/g" \
      -e "s/\"${OLD_INIT_VERSION}\"/\"${NEW_INIT_VERSION}\"/g" \
      -e "s/branch: release-${NEW_INIT_VERSION}/branch: release-${TARGET_VERSION}/g" \
      -e "s/variant: ${arch_stream}-${NEW_INIT_VERSION}-cpou-upgrade-from-${OLD_INIT_VERSION}/variant: ${arch_stream}-${TARGET_VERSION}-cpou-upgrade-from-${NEW_INIT_VERSION}/g" \
      "$file" > "$new_file"
  
  # Update cron settings
  tools/update-cron-entries.py --backup no "$new_file"

  echo "$new_file"
done
