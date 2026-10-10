#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SNAPSHOT_WITHOUT="${SHARED_DIR}/day0-snapshot-without-netobserv.json"
SNAPSHOT_WITH="${SHARED_DIR}/day0-snapshot-with-netobserv.json"
REPORT="${ARTIFACT_DIR}/day0-resource-diff.txt"
HTML_REPORT="${ARTIFACT_DIR}/day0-resource-diff.html"
SPYGLASS_LINK="${ARTIFACT_DIR}/custom-link-day0-report.html"
DAY0_ARTIFACTS_BASE=""
ORION_ARTIFACTS_BASE=""
ORION_WORKERS="${COMPUTE_NODE_REPLICAS:-}"

# Build absolute links to this step and the later Orion step. The URL path
# mirrors ci-operator's public artifact layout.
if [[ -n "${JOB_NAME:-}" && -n "${BUILD_ID:-}" && -n "${JOB_NAME_SAFE:-}" ]]; then
    if [[ "${JOB_TYPE:-}" == "presubmit" && -n "${PULL_NUMBER:-}" && -n "${REPO_OWNER:-}" && -n "${REPO_NAME:-}" ]]; then
        GCS_JOB_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
    else
        GCS_JOB_PATH="logs/${JOB_NAME}/${BUILD_ID}"
    fi
    GCS_BUCKET="${GCS_PUBLIC_BUCKET:-test-platform-results-public}"
    GCS_ARTIFACT_BASE="${GCS_ARTIFACT_BASE:-https://gcs.ci.openshift.org/gcs/${GCS_BUCKET}}"
    JOB_ARTIFACTS_BASE="${GCS_ARTIFACT_BASE}/${GCS_JOB_PATH}/artifacts/${JOB_NAME_SAFE}"
    DAY0_ARTIFACTS_BASE="${JOB_ARTIFACTS_BASE}/netobserv-day0-diff-resource/artifacts"
    ORION_ARTIFACTS_BASE="${JOB_ARTIFACTS_BASE}/openshift-qe-orion/artifacts"
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

# Memory metrics are reported in bytes, while the network recording rules are
# byte-counter rates normalized per second. Render both using IEC units.
MEMORY_METRIC_PARTS = ("memory", "rss", "workingset", "storageusage")
NETWORK_RATE_METRICS = {"TotalNetworkBytesIn", "TotalNetworkBytesOut"}

def is_memory_metric(metric):
    name = metric.lower()
    return any(part in name for part in MEMORY_METRIC_PARTS)

def format_iec_value(value, units):
    scaled = value
    unit_index = 0
    while abs(scaled) >= 1024 and unit_index < len(units) - 1:
        scaled /= 1024
        unit_index += 1
    return f"{scaled:.2f} {units[unit_index]}"

def format_metric_value(metric, value):
    if is_memory_metric(metric):
        return format_iec_value(value, ("B", "KiB", "MiB", "GiB", "TiB", "PiB"))
    if metric in NETWORK_RATE_METRICS:
        return format_iec_value(value, ("B/s", "KiB/s", "MiB/s", "GiB/s", "TiB/s", "PiB/s"))
    return f"{value:.4f}"

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
    html { color-scheme: dark; }
    * { box-sizing: border-box; }
    body {
      background-color: #303030;
      color: #eee;
      font-family: "Roboto", "Helvetica", "Arial", sans-serif;
      font-size: 14px;
      margin: 0;
      padding: 16px;
    }
    h1 { font-size: 20px; margin: 0 0 8px; }
    p { color: #ccc; margin: 0 0 16px; }
    pre {
      background: #212121;
      border: 1px solid #555;
      border-radius: 4px;
      color: #eee;
      line-height: 1.4;
      margin: 0;
      max-width: 100%;
      overflow-x: auto;
      padding: 16px;
    }
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

# Spyglass renders custom-link-*.html files directly in the expanded HTML lens.
# Include the report body for a quick view and use absolute public GCS URLs for
# links because relative URLs resolve under /spyglass/static/html/.
export REPORT SPYGLASS_LINK DAY0_ARTIFACTS_BASE ORION_ARTIFACTS_BASE ORION_WORKERS
python - <<'PYEOF'
from html import escape
import os

report_path = os.environ["REPORT"]
spyglass_path = os.environ["SPYGLASS_LINK"]
day0_base = os.environ.get("DAY0_ARTIFACTS_BASE", "")
orion_base = os.environ.get("ORION_ARTIFACTS_BASE", "")
orion_workers = os.environ.get("ORION_WORKERS", "")

with open(report_path) as f:
    report = f.read()

def artifact_link(label, url, title):
    return (
        f'<a class="artifact-link" target="_blank" '
        f'href="{escape(url, quote=True)}" title="{escape(title, quote=True)}">'
        f'{escape(label)}</a>'
    )

parts = ["""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>NetObserv Day0 reports</title>
  <link rel="stylesheet" type="text/css" href="/static/spyglass/spyglass.css">
  <style>
    html { color-scheme: dark; }
    * { box-sizing: border-box; }
    body {
      background-color: #303030;
      color: #eee;
      font-family: "Roboto", "Helvetica", "Arial", sans-serif;
      font-size: 14px;
      margin: 0;
      padding: 16px;
    }
    h1 { font-size: 18px; margin: 0 0 12px; }
    h2 { color: #90caf9; font-size: 15px; margin: 18px 0 8px; }
    .artifact-links {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      max-width: 100%;
    }
    .artifact-link {
      align-items: center;
      background-color: #4e9af1;
      border: 2px solid #4e9af1;
      border-radius: 1em;
      color: #fff !important;
      display: inline-flex;
      line-height: 1.3;
      max-width: 100%;
      overflow-wrap: anywhere;
      padding: 6px 14px;
      text-decoration: none;
      white-space: normal;
    }
    .artifact-link:hover { border-color: #fff; }
    pre {
      background: #212121;
      border: 1px solid #555;
      border-radius: 4px;
      color: #eee;
      font-size: 13px;
      line-height: 1.4;
      margin: 0;
      max-width: 100%;
      overflow-x: auto;
      padding: 16px;
    }
  </style>
</head>
<body>
  <h1>NetObserv Day0 reports</h1>
"""]

if day0_base:
    parts.extend([
        '<nav class="artifact-links" aria-label="NetObserv reports">',
        artifact_link(
            "NetObserv day0 resource diff",
            f"{day0_base}/day0-resource-diff.html",
            "Open the complete NetObserv day0 resource impact report",
        ),
        "</nav>",
    ])

parts.extend([
    "<h2>Resource diff</h2>",
    f"<pre>{escape(report)}</pre>",
])

if orion_base:
    parts.extend([
        "<h2>Orion artifacts</h2>",
        '<nav class="artifact-links" aria-label="Orion artifacts">',
        artifact_link("Orion output", f"{orion_base}/orion-output.txt", "Open Orion command output"),
    ])
    if orion_workers:
        baseline_viz = f"output_netobserv-day0-baseline-AWS-{orion_workers}w_viz.html"
        enabled_viz = f"output_netobserv-day0-with-noo-AWS-{orion_workers}w_viz.html"
        parts.extend([
            artifact_link(
                "Orion baseline visualization",
                f"{orion_base}/{baseline_viz}",
                "Open the Orion visualization for the baseline measurement",
            ),
            artifact_link(
                "Orion with NetObserv visualization",
                f"{orion_base}/{enabled_viz}",
                "Open the Orion visualization for the enabled measurement",
            ),
        ])
    parts.append(artifact_link(
        "All Orion artifacts",
        f"{orion_base}/",
        "Browse all Orion artifacts, including any additional visualizations",
    ))
    parts.append("</nav>")

parts.append("</body>\n</html>\n")
with open(spyglass_path, "w") as f:
    f.write("\n".join(parts))
PYEOF
echo "Spyglass link written to ${SPYGLASS_LINK}"
