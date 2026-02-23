#!/bin/bash
set -e
set -o pipefail

echo "Current working directory: $(pwd)"
echo "Contents of current directory:"
ls -la
echo "Checking for clusters directory in various locations..."

# Try different possible paths for the clusters directory
CLUSTERS_PATH=""
for path in "clusters" "/go/src/github.com/openshift/release/clusters" "/workspace/clusters" "/tmp/clusters"; do
  if [[ -d "$path" ]]; then
    echo "Found clusters directory at: $path"
    CLUSTERS_PATH="$path"
    break
  fi
done

if [[ -z "$CLUSTERS_PATH" ]]; then
  echo "ERROR: Could not find clusters directory in any expected location"
  echo "Available directories:"
  find . -maxdepth 3 -type d | head -20
  exit 1
fi

echo "Discovering configured ClusterPools..."
find $CLUSTERS_PATH/hosted-mgmt/hive/pools -type f -name '*.yaml' | xargs grep 'kind: ClusterPool' | awk -F: '{print $1}' | xargs /tmp/yq e '[.metadata.namespace, .metadata.name] | join(" ")' | sort > /tmp/clusterpools.configured

if ! [[ -s /tmp/clusterpools.configured ]]; then
  echo "ERROR: Discovered no configured ClusterPools. This probably means something is wrong. Aborting."
  exit 1
fi

echo "Discovering configured ClusterImageSets..."
find $CLUSTERS_PATH/hosted-mgmt/hive/pools -type f -name '*.yaml' | xargs grep 'kind: ClusterImageSet' | awk -F: '{print $1}' | xargs /tmp/yq -N e '.metadata.name' | sort > /tmp/imgsets.configured

if ! [[ -s /tmp/imgsets.configured ]]; then
  echo "ERROR: Discovered no configured ClusterImageSets. This probably means something is wrong. Aborting."
  exit 1
fi

echo "Getting extant ClusterPools..."
oc --context hosted-mgmt get clusterpool -A -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' | sort > /tmp/clusterpools.extant

comm -13 /tmp/clusterpools.configured /tmp/clusterpools.extant > /tmp/clusterpools.stale

if [[ -s /tmp/clusterpools.stale ]]; then
  stale_count=$(wc -l < /tmp/clusterpools.stale)
  echo "Found $stale_count zombie clusterpool(s) to clean up:"
  while read ns name; do
    if [[ $JOB_NAME == rehearse-* ]]; then
      echo "    [REHEARSAL] Would delete: oc --context hosted-mgmt delete clusterpool -n $ns $name"
    else
      echo "Deleting zombie clusterpools"
      oc --context hosted-mgmt delete clusterpool -n $ns $name
    fi
  done < /tmp/clusterpools.stale
else
  echo "No zombie clusterpools to delete!"
fi

echo "Getting extant ClusterImageSets..."
oc --context hosted-mgmt get clusterimageset -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort > /tmp/imgsets.extant

comm -13 /tmp/imgsets.configured /tmp/imgsets.extant > /tmp/imgsets.stale

if [[ -s /tmp/imgsets.stale ]]; then
  stale_count=$(wc -l < /tmp/imgsets.stale)
  echo "Found $stale_count zombie ClusterImageSet(s) to clean up:"
  while read name; do
    if [[ $JOB_NAME == rehearse-* ]]; then
      echo "    [REHEARSAL] Would delete: oc --context hosted-mgmt delete clusterimageset $name"
    else
      echo "Deleting zombie ClusterImageSets"
      oc --context hosted-mgmt delete clusterimageset $name
    fi
  done < /tmp/imgsets.stale
else
  echo "No zombie ClusterImageSets to delete!"
fi
