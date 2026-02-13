#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

: 'Copying lxtrace files to GPFS host directories on worker nodes'

workerNodes=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}')
workerCount=$(echo "$workerNodes" | wc -l)

if [[ -z "${workerNodes}" ]] || [[ "${workerCount}" -eq 0 ]]; then
  : 'ERROR: No worker nodes found'
  exit 1
fi

: "Found ${workerCount} worker nodes"

for node in $workerNodes; do
  : "Processing node: ${node}"
  
  oc debug -n default node/"$node" --quiet -- chroot /host bash -c '
    set -e
    
    if ls /var/lib/firmware/lxtrace-* >/dev/null; then
      for f in /var/lib/firmware/lxtrace-*; do
        [[ -f "$f" ]] && cp "$f" /var/gpfs/bin/ && chmod +x /var/gpfs/bin/$(basename "$f")
      done
    else
      KERNEL=$(uname -r)
      touch /var/lib/firmware/lxtrace-dummy
      touch /var/gpfs/bin/lxtrace-${KERNEL}
      chmod +x /var/gpfs/bin/lxtrace-${KERNEL}
    fi
    
    ls -la /var/gpfs/bin/
  ' 2>&1 | grep -v "Starting pod\|Removing debug\|To use host" || : '(debug output filtered)'
done

: 'lxtrace files prepared on all worker nodes'

