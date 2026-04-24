#!/usr/bin/env python3
# Regenerates build-farm entries in ship-status configs from _clusters.yaml.
# Run from repo root.

import sys
import yaml

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
}


def splice(path, begin, end, body):
    with open(path, encoding="utf-8") as fh:
        t = fh.read()
    bi, ei = t.find(begin), t.find(end)
    if bi == -1 or ei == -1:
        sys.exit(f"markers not found in {path}")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(t[:bi] + begin + body + end + t[ei + len(end):])


with open("core-services/sanitize-prow-jobs/_clusters.yaml", encoding="utf-8") as f:
    data = yaml.safe_load(f)

clusters = sorted(
    {c["name"]: c.get("blocked", False) for entries in data.values() for c in entries if c["name"] in CONSOLE_URLS}.items()
)

monitor_body = ""
dash_body = ""

for name, blocked in clusters:
    console = CONSOLE_URLS[name]
    monitor_body += f"""\
  - component_slug: "build-farm"
    sub_component_slug: "{name}"
    prometheus_monitor:
      prometheus_location:
        cluster: "app.ci"
        namespace: "openshift-monitoring"
        route: "thanos-querier"
      queries:
        - query: "probe_success{{job=\\"blackbox\\",instance=\\"{console}\\"}} > 0"
          duration: "5m"
          step: "30s"
          severity: "Down"
"""
    if not blocked:
        monitor_body += f"""\
        - query: "rate(prowjob_state_transitions{{cluster=\\"{name}\\",state=\\"success\\"}}[2h]) > 0"
          duration: "2h"
          step: "5m"
          severity: "Degraded"
"""

    display = "Build" + name[5:]
    desc = f"Build cluster {name}" + (" (out of rotation)" if blocked else "")
    dash_body += f'      - name: "{display}"\n        description: "{desc}"\n'
    if blocked:
        dash_body += f'        long_description: "{display} is blocked and out of rotation. Console reachability is still monitored. See core-services/sanitize-prow-jobs/_clusters.yaml."\n'
    dash_body += """\
        monitoring:
          frequency: 5m
          component_monitor: "app-ci-component-monitor"
          auto_resolve: true
        requires_confirmation: false
"""

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

for name, blocked in clusters:
    print(f"  {name}: {'blocked' if blocked else 'active'}")
