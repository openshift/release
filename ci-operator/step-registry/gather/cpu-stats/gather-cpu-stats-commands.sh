#!/bin/bash
set -x

set -euxo pipefail

mkdir -p "${ARTIFACT_DIR}/cpu-stats"

for node in $(oc get nodes -o custom-columns=NAME:.metadata.name --no-headers); do
  echo "Gathering top CPU processes on ${node}"
  oc -n default debug node/"${node}" -- chroot /host bash -c "
    echo 'pid comm cpu_ticks'
    for pid in \$(ls /proc | grep -E '^[0-9]+\$'); do
      stat_file=\"/proc/\$pid/stat\"
      if [[ -r \"\$stat_file\" ]]; then
        read -r pid comm _ < <(cut -d' ' -f1-2 \"\$stat_file\")
        comm=\"\${comm//[\(\)]/}\"
        utime=\$(cut -d' ' -f14 \"\$stat_file\")
        stime=\$(cut -d' ' -f15 \"\$stat_file\")
        total=\$((utime + stime))
        echo \"\$pid \$comm \$total\"
      fi
    done | sort -k3 -nr | head -n 25
  " > "${ARTIFACT_DIR}/cpu-stats/${node}.txt" || echo "Failed to collect from ${node}"
done