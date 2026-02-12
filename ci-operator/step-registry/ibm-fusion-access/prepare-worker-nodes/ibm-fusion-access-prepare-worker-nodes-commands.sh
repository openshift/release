#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "🔧 Preparing worker nodes for IBM Storage Scale..."

# Get worker nodes
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}')
WORKER_COUNT=$(echo "$WORKER_NODES" | wc -l)

echo "Found $WORKER_COUNT worker nodes:"
echo "$WORKER_NODES"
echo ""

# Function to create directory on node
create_directory_on_node() {
  local node=$1
  local dir=$2
  
  echo "  Creating $dir..."
  
  if oc debug -n default node/"$node" -- chroot /host mkdir -p "$dir" >/dev/null; then
    echo "  ✅ $dir created on $node"
    return 0
  else
    echo "  ❌ Failed to create $dir on $node"
    return 1
  fi
}

# Create required directories on each worker node
echo "Creating required directories on worker nodes..."
for node in $WORKER_NODES; do
  echo ""
  echo "Processing node: $node"
  
  # Create /var/lib/firmware (required by mmbuildgpl for kernel module build)
  if ! create_directory_on_node "$node" "/var/lib/firmware"; then
    echo "❌ Failed to prepare node $node - directory creation failed"
    exit 1
  fi
  
  # Create /var/mmfs directories (required by IBM Storage Scale)
  if ! create_directory_on_node "$node" "/var/mmfs/etc"; then
    echo "❌ Failed to prepare node $node - directory creation failed"
    exit 1
  fi
  if ! create_directory_on_node "$node" "/var/mmfs/tmp/traces"; then
    echo "❌ Failed to prepare node $node - directory creation failed"
    exit 1
  fi
  if ! create_directory_on_node "$node" "/var/mmfs/pmcollector"; then
    echo "❌ Failed to prepare node $node - directory creation failed"
    exit 1
  fi
  
  echo "  ✅ Node $node prepared successfully"
done

echo ""
echo "✅ Worker node preparation complete"
echo "All nodes are ready for IBM Storage Scale daemon deployment"
