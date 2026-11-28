#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# A dedicated post step keeps reporting independent of Orion's exit status.
# The ref is best_effort so report failures cannot change the test verdict.
python - <<'PYTHON_NETOBSERV_REPORT'
import datetime
import hashlib
import html
import json
import math
import os
import time
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen
from urllib.parse import quote, urlencode

env = os.environ
artifacts = Path(env["ARTIFACT_DIR"])
artifacts.mkdir(parents=True, exist_ok=True)
parts = []
warnings = []


def escape(value):
    """Escape a value for HTML text and attributes."""
    return html.escape(str(value), quote=True)


def sample_reference(uuid):
    """Return a stable display reference without revealing the workload UUID."""
    if not uuid:
        return "Unavailable"
    return "sample-" + hashlib.sha256(str(uuid).encode()).hexdigest()[:12]


def read_json(path):
    """Read local run identity, recording a notice if it is unavailable."""
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        warnings.append(f"Could not read {path.name}: {error}")
        return None


def timestamp(value):
    """Format a Unix timestamp in UTC, handling missing or invalid values."""
    try:
        return datetime.datetime.fromtimestamp(float(value), datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    except (TypeError, ValueError, OverflowError, OSError):
        return "Unknown"


def number(value):
    """Format finite metric values and label missing measurements unavailable."""
    if not isinstance(value, (int, float)) or not math.isfinite(value):
        return "Unavailable"
    return f"{value:,.6g}"


def table(headers, rows):
    """Build a scrollable table with escaped headers and cell contents."""
    return '<div class="scroll"><table><thead><tr>' + ''.join(
        f"<th>{escape(h)}</th>" for h in headers
    ) + '</tr></thead><tbody>' + ''.join(
        '<tr>' + ''.join(f"<td>{escape(cell)}</td>" for cell in row) + '</tr>' for row in rows
    ) + '</tbody></table></div>'


def link(url, label):
    """Build an escaped artifact link that opens in a separate tab."""
    return f'<a href="{escape(url)}" target="_blank" rel="noopener noreferrer">{escape(label)}</a>'


job = env.get("JOB_NAME", "")
build = env.get("BUILD_ID", "")
test = env.get("JOB_NAME_SAFE", "")
job_path = ["logs", job, build]
if env.get("JOB_TYPE") == "presubmit":
    # JOB_SPEC identifies the PR whose artifacts are stored, including rehearsals.
    try:
        spec = json.loads(env.get("JOB_SPEC") or "{}")
    except ValueError:
        spec = {}
        warnings.append("Could not parse JOB_SPEC; using the PR environment for artifact links.")
    refs = spec.get("refs") or {}
    pulls = refs.get("pulls") or []
    owner = refs.get("org") or env.get("REPO_OWNER", "")
    repo = refs.get("repo") or env.get("REPO_NAME", "")
    pull = str(pulls[0]["number"]) if pulls else env.get("PULL_NUMBER", "")
    job_path = ["pr-logs", "pull", f"{owner}_{repo}", pull, job, build] if owner and repo and pull else []
base = ""
if job and build and test and job_path:
    path = job_path + ["artifacts", test, "openshift-qe-orion"]
    base = "https://gcs.ci.openshift.org/gcs/test-platform-results-public/" + '/'.join(quote(p, safe="") for p in path)

identity_path = Path(env.get("SHARED_DIR", "/tmp")) / "orion-current-run.json"
identity = read_json(identity_path) if identity_path.is_file() else None
current_uuid = ""
if isinstance(identity, dict) and build and identity.get("build_id") == build:
    current_uuid = identity.get("uuid") or ""
else:
    identity = {}

# Read the completed step's public artifacts; step sidecars upload before the
# next step starts. The public mirror can lag, so wait briefly for finished.json.
# This post step also runs when Orion failed or was never reached.
def fetch_json(url):
    """Fetch a public artifact or object listing with a bounded socket timeout."""
    with urlopen(url, timeout=20) as response:
        return json.load(response)


objects = []
finished = {}
artifact_names = []
if base:
    prefix = '/'.join(path) + '/'
    for attempt in range(6):
        try:
            objects = []
            token = ""
            while True:
                query = {"prefix": prefix, "fields": "items(name),nextPageToken"}
                if token:
                    query["pageToken"] = token
                listing = fetch_json("https://storage.googleapis.com/storage/v1/b/test-platform-results-public/o?" + urlencode(query))
                objects.extend(listing.get("items", []))
                token = listing.get("nextPageToken", "")
                if not token:
                    break
            if any(item["name"] == prefix + "finished.json" for item in objects):
                finished = fetch_json("https://storage.googleapis.com/test-platform-results-public/" + quote(prefix + "finished.json", safe="/"))
                break
        except (OSError, URLError, ValueError) as error:
            if attempt == 5:
                warnings.append(f"Could not read Orion artifacts: {error}")
        if attempt < 5:
            time.sleep(5)
    artifact_prefix = prefix + "artifacts/"
    artifact_names = sorted(item["name"][len(artifact_prefix):] for item in objects
                            if item["name"].startswith(artifact_prefix)
                            and "/" not in item["name"][len(artifact_prefix):])

status = "Orion step results unavailable (step skipped or artifacts not yet available)"
if finished.get("passed") is True:
    status = "Orion step passed"
elif finished.get("passed") is False:
    status = "Orion step failed — inspect the analysis output and step log"
if env.get("RUN_ORION") == "false":
    status = "Analysis disabled"
parts.append('<h1>NetObserv performance report</h1><h2>This run</h2>')
parts.append(f'<p class="status">{escape(status)}</p>')
parts.append(table(["Detail", "Value"], [
    ("Job", job or "Unknown"), ("Build", build or "Unknown"), ("Test", test or "Unknown"),
    ("Workload", (identity or {}).get("workload", "Unknown") if isinstance(identity, dict) else "Unknown"),
    ("Sample reference", sample_reference(current_uuid)),
    ("Configuration", env.get("ORION_CONFIG", "")),
    ("Parameters", env.get("ORION_ENVS", "")),
    ("OpenShift version filter", env.get("VERSION", "")),
    ("Orion step finished", timestamp(finished.get("timestamp"))),
]))
parts.append('<p>The step status applies to the whole Orion analysis. A failed step can indicate regressions in the lookback window or an analysis error; it does not by itself identify a new regression in this run.</p>')
if env.get("RUN_ORION") == "deferred":
    parts.append('<p>Orion failure enforcement is deferred to a later step.</p>')
if base:
    links = [link(base + "/build-log.txt", "Step log"), link(base + "/artifacts/", "Artifacts")]
    for name in artifact_names:
        if Path(name).suffix in {".json", ".csv", ".txt", ".xml", ".yaml"}:
            links.append(link(base + "/artifacts/" + quote(name, safe=""), name))
    parts.append('<details><summary>Logs and analysis artifacts</summary><ul>' + ''.join(f"<li>{item}</li>" for item in links) + '</ul></details>')
else:
    parts.append('<p>Artifact links unavailable: job storage metadata is incomplete.</p>')

datasets = []
for name in artifact_names:
    if not (name.startswith("output_") and name.endswith(".json")):
        continue
    path = Path(name)
    try:
        rows = fetch_json("https://storage.googleapis.com/test-platform-results-public/" + quote(prefix + "artifacts/" + name, safe="/"))
    except (OSError, URLError, ValueError) as error:
        warnings.append(f"Could not read {name}: {error}")
        continue
    if not isinstance(rows, list) or not all(isinstance(row, dict) and isinstance(row.get("metrics"), dict) for row in rows):
        warnings.append(f"{path.name} does not contain an Orion sample list.")
        continue
    datasets.append((path, rows))

matched = False
for path, rows in datasets:
    samples = [row for row in rows if current_uuid and row.get("uuid") == current_uuid]
    if not samples:
        continue
    matched = True
    parts.append(f'<h3>Current sample: {escape(path.stem.removeprefix("output_"))}</h3>')
    for row in samples:
        parts.append(f'<p>Sample time: {escape(timestamp(row.get("timestamp")))} · OpenShift: {escape(row.get("ocpVersion", "Unknown"))} · NetObserv bundle: {escape(row.get("noo_bundle_info", "Unknown"))}</p>')
        metric_rows = []
        for name, metric in sorted(row["metrics"].items()):
            if not isinstance(metric, dict):
                continue
            changed = metric.get("is_changepoint") is True
            metric_rows.append((name, number(metric.get("value")),
                                number(metric.get("percentage_change")) + "%" if changed else "—",
                                "Change point at this sample" if changed else "No change point at this sample"))
        parts.append(table(["Metric", "Value", "Change at this sample", "Detection"], metric_rows))
if not current_uuid:
    parts.append('<p class="notice">Current-run identity unavailable. No historical sample has been assumed to be this run.</p>')
elif not datasets:
    parts.append('<p class="notice">No analysis samples are available to match this run.</p>')
elif not matched:
    parts.append('<p class="notice">This run is not present in the analyzed samples. Current-run metrics are unavailable; the historical results below may still contain changes.</p>')

parts.append('<h2>Historical context</h2>')
parts.append(f'<p>Snapshot generated by this build. Requested lookback: {escape(env.get("LOOKBACK", "Unknown"))} days; sample limit: {escape(env.get("LOOKBACK_SIZE") or "not specified")}. These are the results saved at analysis time, not live results.</p>')
for path, rows in datasets:
    times = [row.get("timestamp") for row in rows if isinstance(row.get("timestamp"), (int, float)) and math.isfinite(row["timestamp"])]
    title = path.stem.removeprefix("output_")
    parts.append(f'<h3>{escape(title)}</h3><p>{len(rows)} analyzed samples. Observed window: {escape(timestamp(min(times)) if times else "Unknown")} – {escape(timestamp(max(times)) if times else "Unknown")}.</p>')
    changes = []
    for row in rows:
        for name, metric in row["metrics"].items():
            if isinstance(metric, dict) and metric.get("is_changepoint") is True:
                changes.append((timestamp(row.get("timestamp")), sample_reference(row.get("uuid")),
                                "This run" if current_uuid and row.get("uuid") == current_uuid else "Historical sample",
                                name, number(metric.get("percentage_change")) + "%"))
    if changes:
        parts.append('<details><summary>Change points in the lookback window</summary><p>Detected shifts may include improvements or acknowledged changes; they are not all new regressions in this run.</p>')
        parts.append(table(["Sample time", "Sample reference", "Scope", "Metric", "Change"], changes) + '</details>')
    else:
        parts.append('<p>No change points recorded in this dataset.</p>')
if not datasets:
    parts.append('<p>No structured analysis results available. Check the step log for details.</p>')

graphs = [Path(name) for name in artifact_names if name.endswith("_viz.html")]
graph_context = "Use the current sample timestamp above to locate this run." if matched else "No current-run sample was matched; these graphs provide historical context only."
for path in graphs:
    if not base:
        continue
    url = base + "/artifacts/" + quote(path.name, safe="")
    parts.append(f'<p>{link(url, "Open full graphs: " + path.name)}</p>')
    parts.append(f'<details class="graphs"><summary>Show historical graphs: {escape(path.stem.removesuffix("_viz").removeprefix("output_"))}</summary><p>Graphs show the saved lookback window. {graph_context}</p><iframe title="{escape(path.name)}" data-src="{escape(url)}" sandbox="allow-scripts allow-same-origin allow-popups"></iframe></details>')
if not graphs:
    parts.append('<p>No historical graph artifacts available.</p>')
if warnings:
    parts.append('<h3>Report notices</h3><ul>' + ''.join(f'<li>{escape(warning)}</li>' for warning in warnings) + '</ul>')

document = '''<!doctype html>
<html><head><meta charset="utf-8"><title>NetObserv performance report</title>
<meta name="description" content="Current-run metrics and historical performance context saved by this build.">
<style>
body { font: 14px system-ui, sans-serif; background: #303030; color: #eee; margin: 0; padding: 16px; }
h1 { font-size: 21px; } h2 { margin-top: 24px; color: #90caf9; } h3 { font-size: 16px; }
a { color: #80d8ff; } p { line-height: 1.5; } .status { font-weight: bold; }
.notice { padding: 12px; border-left: 3px solid #ffcc80; } .scroll { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; } th, td { text-align: left; border-bottom: 1px solid #555; padding: 8px; overflow-wrap: anywhere; }
th { background: #212121; } details { margin: 16px 0; } summary { cursor: pointer; color: #90caf9; }
li { margin: 6px 0; overflow-wrap: anywhere; } iframe { width: 100%; height: 720px; border: 0; background: white; }
</style></head><body>''' + ''.join(parts) + '''
<script>
// Load Plotly only after expansion so it has a visible container to size itself.
document.querySelectorAll('details.graphs').forEach(function (section) {
  section.addEventListener('toggle', function () {
    var frame = section.querySelector('iframe');
    if (section.open && !frame.hasAttribute('src')) frame.src = frame.dataset.src;
  });
});
</script></body></html>'''
(artifacts / "custom-link-orion.html").write_text(document)
PYTHON_NETOBSERV_REPORT
