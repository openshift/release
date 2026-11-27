#!/bin/bash
set -uo pipefail
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
[[ -s $SHARED_DIR/vrrp-upgrade-start ]] || { echo "No completed observer setup"; exit 0; }
start=$(<"$SHARED_DIR/vrrp-upgrade-start")
[[ $start =~ ^[0-9]+$ ]] || exit 1
oc get clusterversion version -o json | jq '.status.history[:3]' > "$ARTIFACT_DIR/version-history.json"
for node in $(oc get nodes -l node-role.kubernetes.io/master -o name); do
  name=${node#node/}
  oc debug -n default "$node" -- chroot /host journalctl --since="@$start" -o short-iso-precise \
    -u vrrp-upgrade-observe -u vrrp-upgrade-peer --no-pager |
    grep -E 'vip=|_API_0\)|-- Boot ' > "$ARTIFACT_DIR/$name-handoff.txt"
  oc adm node-logs "$name" --path=kube-apiserver/termination.log > "$ARTIFACT_DIR/$name-termination.log"
done
# Best effort: missing observations are inconclusive. Always run the regular
# gather and deprovision chain, including when the upgrade itself failed.
exit 0
