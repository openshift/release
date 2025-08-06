#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "🔧 Preparing worker nodes for IBM Storage Scale..."

# Get worker nodes
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}')
WORKER_COUNT=$(echo "$WORKER_NODES" | wc -l)

echo "Found $WORKER_COUNT worker nodes:"
echo "$WORKER_NODES"
echo ""

# Function to create and verify directory on node
create_directory_on_node() {
  local node=$1
  local dir=$2
  
  echo "  Creating $dir..."
  
  # Create directory and capture full output
  local output
  output=$(oc debug -n default node/"$node" -- chroot /host mkdir -p "$dir" 2>&1 || true)
  
  # Filter out expected debug pod messages
  local filtered
  filtered=$(echo "$output" | grep -v "Starting pod\|Removing debug pod\|To use host binaries" | grep -v "^$" || true)
  
  # Check for error indicators in output
  if echo "$filtered" | grep -qiE "error|unable to|not found|cannot|failed|permission denied"; then
    echo "  ❌ Failed to create $dir on $node:"
    echo "$filtered" | sed 's/^/     /'
    return 1
  fi
  
  # Verify directory actually exists
  if ! oc debug -n default node/"$node" -- chroot /host test -d "$dir" >/dev/null 2>&1; then
    echo "  ❌ Directory $dir does not exist on $node after creation attempt"
    return 1
  fi
  
  echo "  ✅ $dir created and verified on $node"
  return 0
}

# Track failed nodes
FAILED_NODES=()

# Create required directories on each worker node
echo "Creating required directories on worker nodes..."
for node in $WORKER_NODES; do
  echo "Processing node: $node"
  
  # Create /var/lib/firmware directory (required by mmbuildgpl for kernel module build)
  if ! create_directory_on_node "$node" "/var/lib/firmware"; then
    FAILED_NODES+=("$node")
    echo "  ❌ Failed to prepare node: $node"
    echo ""
    continue
  fi
  
  # Create /var/mmfs directories (required by IBM Storage Scale)
  if ! create_directory_on_node "$node" "/var/mmfs/etc"; then
    FAILED_NODES+=("$node")
    echo "  ❌ Failed to prepare node: $node"
    echo ""
    continue
  fi
  
  if ! create_directory_on_node "$node" "/var/mmfs/tmp/traces"; then
    FAILED_NODES+=("$node")
    echo "  ❌ Failed to prepare node: $node"
    echo ""
    continue
  fi
  
  if ! create_directory_on_node "$node" "/var/mmfs/pmcollector"; then
    FAILED_NODES+=("$node")
    echo "  ❌ Failed to prepare node: $node"
    echo ""
    continue
  fi
  
  echo "  ✅ All directories created successfully on $node"
  echo ""
done

# Check if any nodes failed
if [ ${#FAILED_NODES[@]} -gt 0 ]; then
  echo "❌ Failed to prepare the following nodes:"
  printf '  - %s\n' "${FAILED_NODES[@]}"
  echo ""
  echo "Worker node preparation FAILED!"
  exit 1
fi

echo "✅ Worker node preparation completed successfully!"
echo "All nodes are ready for IBM Storage Scale daemon deployment"

