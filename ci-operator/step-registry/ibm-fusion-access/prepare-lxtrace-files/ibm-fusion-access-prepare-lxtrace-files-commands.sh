#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

echo "🔧 Creating lxtrace dummy files on worker nodes..."
echo "NOTE: IBM Storage Scale buildgpl script expects lxtrace files in /var/lib/firmware"
echo ""

# Get worker nodes
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}')
WORKER_COUNT=$(echo "$WORKER_NODES" | wc -l)

echo "Found $WORKER_COUNT worker nodes"
echo ""

# Create lxtrace dummy files on each worker node
for node in $WORKER_NODES; do
  echo "Processing node: $node"
  
  # Create dummy lxtrace file in /var/lib/firmware
  # This is required by the buildgpl script's rsync command
  # Note: Using -n default for debug pod namespace
  oc debug -n default node/$node -- chroot /host bash -c 'touch /var/lib/firmware/lxtrace-dummy && chmod 644 /var/lib/firmware/lxtrace-dummy' 2>&1 | \
    grep -v "Starting pod\|Removing debug\|To use host" || true
  
  # Verify file was created
  if oc debug -n default node/$node -- chroot /host test -f /var/lib/firmware/lxtrace-dummy >/dev/null; then
    echo "  ✅ lxtrace-dummy created and verified"
  else
    echo "  ❌ Failed to create lxtrace-dummy"
    exit 1
  fi
done

echo ""
echo "✅ lxtrace dummy files created on all worker nodes"
echo "   Location: /var/lib/firmware/lxtrace-dummy"
echo "   Purpose: Satisfy buildgpl script rsync requirement"

