#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SNAPSHOT_WITHOUT="${SHARED_DIR}/day0-snapshot-without-netobserv.json"
SNAPSHOT_WITH="${SHARED_DIR}/day0-snapshot-with-netobserv.json"
REPORT="${ARTIFACT_DIR}/day0-resource-diff.txt"

if [[ ! -f "${SNAPSHOT_WITHOUT}" ]]; then
    echo "ERROR: without-netobserv snapshot not found at ${SNAPSHOT_WITHOUT}" >&2
    exit 1
fi
if [[ ! -f "${SNAPSHOT_WITH}" ]]; then
    echo "ERROR: with-netobserv snapshot not found at ${SNAPSHOT_WITH}" >&2
    exit 1
fi

echo "Computing day0 resource diff..."

python - <<PYEOF
import json, os, sys

snapshot_without = "${SNAPSHOT_WITHOUT}"
snapshot_with    = "${SNAPSHOT_WITH}"
env_summary_path = "${SHARED_DIR}/day0-env-summary.json"
report_path      = "${REPORT}"
metrics_filter   = set("${DIFF_METRICS}".split(","))

def load_averages(path):
    with open(path) as f:
        data = json.load(f)
    averages = {}
    for entry in data.get("prometheus_data", []):
        name = entry.get("metric_name")
        if name not in metrics_filter:
            continue
        raw = entry.get("raw_data", {})
        values = []
        for result in raw.get("data", {}).get("result", []):
            for _, v in result.get("values", []):
                try:
                    values.append(float(v))
                except (ValueError, TypeError):
                    pass
        if values:
            averages[name] = sum(values) / len(values)
    return averages

without = load_averages(snapshot_without)
with_noo = load_averages(snapshot_with)

# Load environment summary written by patch-cno step
env = {}
if os.path.exists(env_summary_path):
    with open(env_summary_path) as f:
        env = json.load(f)
fc = env.get("flowcollector", {})

lines = []
lines.append("=" * 72)
lines.append("  NetObserv Day0 Resource Impact Report")
lines.append("  Comparing cluster resource usage before and after CNO installation")
lines.append("=" * 72)
lines.append("")
lines.append("  Environment")
lines.append("  -----------")
lines.append(f"  OCP Version       : {env.get('ocp_version', 'N/A')}")
lines.append(f"  Worker Nodes      : {env.get('worker_count', 'N/A')} x {env.get('worker_instance_type', 'N/A')}")
lines.append(f"  Deployment Model  : {fc.get('deployment_model', 'N/A')}")
lines.append(f"  eBPF Sampling     : {fc.get('sampling', 'N/A')}")
lines.append(f"  Loki              : {'enabled' if fc.get('loki_enabled') else 'disabled'}")
lines.append("")
lines.append("=" * 72)
lines.append(f"  {'Metric':<42} {'Without NOO':>12} {'With NOO':>12} {'Delta':>10} {'% Change':>10}")
lines.append("-" * 72)

for metric in sorted(metrics_filter):
    v_without = without.get(metric)
    v_with    = with_noo.get(metric)
    if v_without is None and v_with is None:
        lines.append(f"  {metric:<40} {'N/A':>12} {'N/A':>12} {'N/A':>10} {'N/A':>10}")
        continue
    v_without = v_without or 0.0
    v_with    = v_with    or 0.0
    delta     = v_with - v_without
    pct       = (delta / v_without * 100) if v_without != 0 else float("inf")
    delta_str = f"{delta:+.4f}"
    pct_str   = f"{pct:+.1f}%" if pct != float("inf") else "+inf%"
    lines.append(
        f"  {metric:<40} {v_without:>12.4f} {v_with:>12.4f} {delta_str:>10} {pct_str:>10}"
    )

lines.append("=" * 72)
report = "\n".join(lines)
print(report)
with open(report_path, "w") as f:
    f.write(report + "\n")
print(f"\nReport written to {report_path}")
PYEOF
