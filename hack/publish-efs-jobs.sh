#!/bin/bash
# Publish managed repository jobs to EFS and ask the cluster writer to refresh
# the fallback cluster values immediately. The trigger is best-effort: the
# writer's periodic pass catches up if it is unavailable.
set -euo pipefail

ci-operator-prowgen "$@"

curl --fail --silent --show-error --retry 3 --retry-connrefused --retry-all-errors --max-time 10 \
  -X POST "${EFS_CLUSTER_WRITER_URL:-http://efs-cluster-writer.ci.svc.cluster.local:8080/reconcile}" \
  || echo "WARNING: could not trigger the EFS cluster writer; the periodic pass will converge" >&2
