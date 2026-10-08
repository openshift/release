#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SNAPSHOT_WITHOUT="${SHARED_DIR}/day0-snapshot-without-netobserv.json"
SNAPSHOT_WITH="${SHARED_DIR}/day0-snapshot-with-netobserv.json"
REPORT="${ARTIFACT_DIR}/day0-resource-diff.txt"
HTML_REPORT="${ARTIFACT_DIR}/day0-resource-diff.html"
SPYGLASS_LINK="${ARTIFACT_DIR}/custom-link-day0-report.html"
ORION_ARTIFACTS_BASE=""

# The Orion step runs after this step. Build links to its eventual artifacts so
# Spyglass can surface them without modifying the shared Orion step. The URL
# path mirrors ci-operator's public artifact layout.
if [[ -n "${JOB_NAME:-}" && -n "${BUILD_ID:-}" && -n "${JOB_NAME_SAFE:-}" ]]; then
    if [[ "${JOB_TYPE:-}" == "presubmit" && -n "${PULL_NUMBER:-}" && -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" ]]; then
        GCS_JOB_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
    else
        GCS_JOB_PATH="logs/${JOB_NAME}/${BUILD_ID}"
    fi
    GCS_BUCKET="${GCS_PUBLIC_BUCKET:-test-platform-results-public}"
    GCSWEB_BASE="${GCS_PUBLIC_BASE:-https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/${GCS_BUCKET}}"
    ORION_ARTIFACTS_BASE="${GCSWEB_BASE}/${GCS_JOB_PATH}/artifacts/${JOB_NAME_SAFE}/openshift-qe-orion/artifacts"
fi

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
html_report_path = "${HTML_REPORT}"
metrics_filter   = set("${DIFF_METRICS}".split(","))

# These metrics are reported by Prometheus in bytes. Render them using IEC
# units (KiB, MiB, GiB, ...) so the report is readable in Spyglass.
MEMORY_METRIC_PARTS = ("memory", "rss", "workingset", "storageusage")

def is_memory_metric(metric):
    name = metric.lower()
    return any(part in name for part in MEMORY_METRIC_PARTS)

def format_metric_value(metric, value):
    if not is_memory_metric(metric):
        return f"{value:.4f}"
    units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")
    scaled = value
    unit_index = 0
    while abs(scaled) >= 1024 and unit_index < len(units) - 1:
        scaled /= 1024
        unit_index += 1
    return f"{scaled:.2f} {units[unit_index]}"

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
    without_str = format_metric_value(metric, v_without)
    with_str = format_metric_value(metric, v_with)
    delta_str = format_metric_value(metric, delta)
    pct_str   = f"{pct:+.1f}%" if pct != float("inf") else "+inf%"
    lines.append(
        f"  {metric:<40} {without_str:>12} {with_str:>12} {delta_str:>10} {pct_str:>10}"
    )

lines.append("=" * 72)
report = "\n".join(lines)
print(report)
with open(report_path, "w") as f:
    f.write(report + "\n")

from html import escape
with open(html_report_path, "w") as f:
    f.write("""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>NetObserv Day0 Resource Impact Report</title>
  <link rel="stylesheet" type="text/css" href="/static/spyglass/spyglass.css">
  <style>
    body { font-family: sans-serif; margin: 2em; }
    pre { background: #f5f5f5; border: 1px solid #ddd; padding: 1em; overflow-x: auto; }
  </style>
</head>
<body>
  <h1>NetObserv Day0 Resource Impact Report</h1>
  <p>Cluster resource usage before and after CNO installs NetObserv.</p>
  <pre>""" + escape(report) + """</pre>
</body>
</html>
""")
print(f"\nReport written to {report_path}")
print(f"HTML report written to {html_report_path}")
PYEOF

# Spyglass recognizes this artifact name and renders its links in the Prow UI.
{
cat <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>NetObserv Day0 reports</title>
  <link rel="stylesheet" type="text/css" href="/static/spyglass/spyglass.css">
</head>
<body>
  <a target="_blank" href="day0-resource-diff.html" title="Open the NetObserv day0 resource impact report">NetObserv day0 resource diff</a>
HTMLEOF
if [[ -n "${ORION_ARTIFACTS_BASE}" ]]; then
  cat <<HTMLEOF
  <h2>Orion artifacts</h2>
  <a target="_blank" href="${ORION_ARTIFACTS_BASE}/output.txt" title="Open Orion command output">Orion output</a>
  <a target="_blank" href="${ORION_ARTIFACTS_BASE}/orion-output.txt" title="Open Orion command output">Orion command output</a>
  <a target="_blank" href="${ORION_ARTIFACTS_BASE}/viz.html" title="Open Orion visualization">Orion visualization</a>
HTMLEOF
fi
cat <<'HTMLEOF'
</body>
</html>
HTMLEOF
} > "${SPYGLASS_LINK}"
echo "Spyglass link written to ${SPYGLASS_LINK}"
