#!/usr/bin/env python3
# Regenerates build-farm entries in ship-status configs from _clusters.yaml.
# Run from repo root.

import sys
import yaml

# Console URLs must match blackbox targets (see clusters/app.ci/.../blackbox_probe.yaml).
# Clusters with blocked: true in _clusters.yaml are emitted as commented YAML blocks.
CONSOLE_URLS = {
    "build01": "https://console.build01.ci.openshift.org",
    "build02": "https://console.build02.ci.openshift.org",
    "build03": "https://console-openshift-console.apps.build03.ci.devcluster.openshift.com",
    "build04": "https://console.build04.ci.openshift.org",
    "build05": "https://console-openshift-console.apps.build05.ci.devcluster.openshift.com",
    "build06": "https://console-openshift-console.apps.build06.ci.devcluster.openshift.com",
    "build07": "https://console-openshift-console.apps.build07.ci.devcluster.openshift.com",
    "build08": "https://console.build08.ci.openshift.org",
    "build09": "https://console-openshift-console.apps.build09.ci.devcluster.openshift.com",
    "build10": "https://console-openshift-console.apps.build10.ci.devcluster.openshift.com",
    "build11": "https://console-openshift-console.apps.build11.ci.devcluster.openshift.com",
    "build12": "https://console-openshift-console.apps.build12.ci.devcluster.openshift.com",
}

BUILD_ORDER = [f"build{i:02d}" for i in range(1, 13)]


def splice(path, begin, end, body):
    with open(path, encoding="utf-8") as fh:
        t = fh.read()
    bi, ei = t.find(begin), t.find(end)
    if bi == -1 or ei == -1:
        sys.exit(f"markers not found in {path}")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(t[:bi] + begin + body + end + t[ei + len(end) :])


def yaml_comment_block(body: str) -> str:
    out = []
    for line in body.splitlines(keepends=True):
        if line.endswith("\n"):
            core, nl = line[:-1], "\n"
        else:
            core, nl = line, ""
        if core.strip() == "":
            out.append("#\n")
        else:
            out.append("# " + core + nl)
    return "".join(out)


def monitor_entry(cluster_name: str, console_url: str) -> str:
    return f"""\
  - component_slug: "build-farm"
    sub_component_slug: "{cluster_name}"
    prometheus_monitor:
      prometheus_location:
        cluster: "app.ci"
        namespace: "openshift-monitoring"
        route: "thanos-querier"
      queries:
        - query: "probe_success{{job=\\"blackbox\\",instance=\\"{console_url}\\"}} > 0"
          duration: "5m"
          step: "30s"
          severity: "Down"
        - query: "rate(prowjob_state_transitions{{cluster=\\"{cluster_name}\\",state=\\"success\\"}}[2h]) > 0"
          duration: "2h"
          step: "5m"
          severity: "Degraded"
    junit_monitor:
      job_name: "periodic-build-farm-canary-{cluster_name}"
      max_age: "2h"
      severity: "Degraded"
      artifact_url_style: "gcs"
      history_runs: 5
      failed_runs_threshold: 3
"""


def dash_entry(cluster_name: str) -> str:
    display = "Build" + cluster_name[5:]
    return f"""\
      - name: "{display}"
        description: "Build cluster {cluster_name}"
        monitoring:
          frequency: 5m
          component_monitor: "app-ci-component-monitor"
          auto_resolve: true
        requires_confirmation: false
"""


with open("core-services/sanitize-prow-jobs/_clusters.yaml", encoding="utf-8") as f:
    data = yaml.safe_load(f)

blocked_by_name = {
    c["name"]: c.get("blocked", False) for entries in data.values() for c in entries if "name" in c
}

monitor_body = ""
dash_body = ""

for name in BUILD_ORDER:
    if name not in CONSOLE_URLS:
        continue
    console = CONSOLE_URLS[name]
    blocked = blocked_by_name.get(name, False)
    if blocked:
        monitor_body += yaml_comment_block(monitor_entry(name, console))
        monitor_body += "#\n"
        dash_body += yaml_comment_block(dash_entry(name))
        dash_body += "#\n"
    else:
        monitor_body += monitor_entry(name, console)
        dash_body += dash_entry(name)

splice(
    "core-services/ship-status/component-monitor-config.yaml",
    "  # BEGIN: auto-generated build-farm entries (hack/generate-build-farm-monitor-config.py)\n",
    "  # END: auto-generated build-farm entries\n",
    monitor_body,
)
splice(
    "core-services/ship-status/dashboard-config.yaml",
    "    # BEGIN: auto-generated build-farm sub_components (hack/generate-build-farm-monitor-config.py)\n",
    "    # END: auto-generated build-farm sub_components\n",
    dash_body,
)

for name in BUILD_ORDER:
    if name not in CONSOLE_URLS:
        continue
    if blocked_by_name.get(name, False):
        print(f"  {name}: commented-out (blocked in _clusters.yaml)")
    else:
        print(f"  {name}: active")
