#!/bin/env python3
import glob
import multiprocessing.dummy as multiprocessing
import subprocess
import sys
import tempfile
import time
import json
import os


exec_cmd = lambda *cmd: subprocess.check_output(cmd).decode('utf-8')
RED = exec_cmd('tput', 'setaf', '1')
GREEN = exec_cmd('tput', 'setaf', '2')
YELLOW = exec_cmd('tput', 'setaf', '3')
BOLD = exec_cmd('tput', 'bold')
RESET = exec_cmd('tput', 'sgr0')
CLEAR = exec_cmd('tput', 'clear')

BLACKLIST = [
    "Failed to GET .",
    "The following repos define a policy or require context",
    "requested job is unknown to prow: rehearse",
    "requested job is unknown to prow: promote",
    "Not enough reviewers found in OWNERS files for files touched by this PR",
    "failed to get path: failed to resolve sym link: failed to read",
    "nil pointer evaluating *v1.Refs.Repo",
    "unrecognized directory name (expected int64)",
    "failed to get reader for GCS object: storage: object doesn't exist",
    "failed to get reader for GCS object: storage: object doesn't exist",
    "googleapi: Error 401: Anonymous caller does not have storage.objects.list access to origin-ci-private., required",
    "has required jobs but has protect: false",
    "Couldn't find/suggest approvers for each files.",
    "remote error: upload-pack: not our ref",
    "fatal: remote error: upload-pack: not our ref",
    "Error getting ProwJob name for source",
    "the cache is not started, can not read objects",
    "owner mismatch request by",
    "Get : unsupported protocol scheme",
    "No available resource",
    "context deadline exceeded",
    "owner mismatch request by ci-op"
]


def run_oc(args):
    command = ['oc', '--context', 'app.ci', '--as', 'system:admin', '--loglevel', '3', '--namespace', 'ci'] + args
    try:
        process = subprocess.run(command, capture_output=True, check=True)
    except subprocess.CalledProcessError as exc:
        print(exc.stderr.decode('utf-8'))
        raise

    return process.stdout.decode('utf-8')


def debug(msg):
    if os.environ.get("DEBUG", "") == "true":
        print(msg)


def main():
    dcs = run_oc(['get', 'deployment', '--output', 'go-template={{ range .items }}{{ $notfirst := false}}{{ range $k, $v := .spec.template.metadata.labels}}{{ if $notfirst}},{{end}}{{$k}}={{$v}}{{$notfirst = true}}{{end}} {{end}}']).split()
    with tempfile.TemporaryDirectory() as log_dir:
        fs = [(display, log_dir), *((highlight, log_dir, x) for x in dcs)]
        with multiprocessing.Pool(len(fs)) as pool:
            for _ in pool.imap_unordered(lambda x: x[0](*x[1:]), fs):
                pass # a check for exceptions is implicit in the iteration


def display(log_dir):
    logs = log_dir + '/*.log'
    while True:
        sys.stdout.write(CLEAR)
        for log in sorted(glob.glob(logs)):
            with open(log, encoding='utf-8') as f:
                if sys.stdout.write(f.read()):
                    sys.stdout.write('\n')
        time.sleep(5)


def highlight(log_dir, dc):
    warn = '"level":"warning"'
    error = '"level":"error"'
    fatal = '"level":"fatal"'
    log = f'{log_dir}/{dc}.log'
    while True:
        debug(f'deployment/{dc}: gathering info')
        header = renderHeader(dc)
        lines = []
        log_lines = []
        for pod in run_oc(['get', 'pods', '--selector', dc, '--output', 'jsonpath={.items[*].metadata.name}']).split():
            debug(f'deployment/{dc}: pod/{pod}: gathering info')
            lines.extend(renderFlavor(pod, dc))
            cmd = ['logs', '--since', '20m', f'pod/{pod}']
            if "deck-internal" in dc:
                cmd += ['--container', 'deck']
            if "component=boskos" in dc and not "-" in dc:
                cmd += ['--container', 'boskos']
            if "release-controller" in dc and "priv" in dc:
                cmd += ['--container', 'controller']
            debug(f'deployment/{dc}: pod/{pod}: getting logs')
            try:
                for l in run_oc(cmd).splitlines():
                    if any(word in l for word in BLACKLIST):
                        continue
                    for marker, key in {
                            '"query":"': "query",
                            '"error":"query ': "error"
                        }.items():
                        if marker in l:
                            data = json.loads(l)
                            data.pop(key)
                            l = json.dumps(data)
                    if warn in l:
                        log_lines.append(YELLOW + l + RESET)
                    elif error in l or fatal in l:
                        log_lines.append(RED + l + RESET)
            except subprocess.CalledProcessError:
                debug(f'deployment/{dc}: pod/{pod}: getting logs failed')

        if not log_lines and not lines:
            header = f'{header} {GREEN}OK{RESET}'
        with open(log, 'w', encoding='utf-8') as f:
            f.write('\n'.join([header, *lines, *log_lines[-5:]]))
        time.sleep(60)


def renderHeader(dc):
    debug(f'deployment/{dc}: rendering header')
    name = run_oc(["get", "deployment", "-l", dc, "-o", "name"]).strip()
    if name == "":
        # Surprise: Deployments may not match their .spec.labelSelector
        replicaset = run_oc(["get", "replicaset", "-l", dc, "-o", 'go-template={{ $wtfWhyNoBreakInTemplate := ""}}{{ range .items }}{{ $wtfWhyNoBreakInTemplate = .metadata.name}}{{end}}{{$wtfWhyNoBreakInTemplate}}'.strip()])
        if replicaset != "":
            name = json.loads(run_oc(["get", "replicaset", replicaset, "-o", "json"])).get("metadata", {}).get("ownerReferences", [])[0].get("name", "")
            name = "deployment/" + name
    if name != "":
        rawdc = json.loads(run_oc(['get', name.rstrip(), '--output', 'json']))
    else:
        rawdc = {}
    spec = rawdc.get("spec", {})
    status = rawdc.get("status", {})
    desired = spec.get("replicas", 0)
    current = status.get("replicas", 0)
    updated = status.get("updatedReplicas", 0)
    available = status.get("availableReplicas", 0)
    version = "<unknown-version>"
    containers = spec.get("template", {}).get("spec", {}).get("containers", [])
    if "deck-internal" in name:
        container_name = "deck"
    elif "priv" in dc and "release-controller" in dc:
        container_name = "controller"
    elif len(containers) == 1:
        container_name = containers[0].get("name", "")
    else:
        container_name = dc
    debug(f'deployment/{dc}: got container name {container_name}')
    for container in containers:
        if container.get("name") == container_name:
            image = container.get("image", "")
            version = image.split(":")[-1]
    headerColor = ''
    if desired != current:
        headerColor = RED

    message = f'{dc} at {version} [{current}/{desired}]'
    if updated != desired:
        message += f' ({desired - updated} stale replicas)'
    if available != desired:
        message += f' ({desired - available} unavailable replicas)'
    header = f'{BOLD}{headerColor}{message}:{RESET}'
    debug(f'deployment/{dc}: got header {header}')
    return header


def renderFlavor(pod, dc):
    debug(f'deployment/{dc}: pod/{pod}: rendering flavor')
    lines = []
    raw = json.loads(run_oc(['get', f'pod/{pod}', '--output', 'json']))
    status = raw.get("status", {})
    phase = status.get("phase", "")
    if phase != "Running":
        reason = status.get("reason", "")
        message = status.get("message", "")
        color = YELLOW
        if phase in ["Failed", "Unknown", "CrashLoopBackOff"]:
            color = RED
        lines.append(color + f'pod {pod} is {phase}: {reason}, {message}')

    for container in status.get("containerStatuses", []):
        debug(f'pod/{pod}: handling status for container {container.get("name", "")}')
        if container.get("name") == dc:
            state = container.get("state", {})
            if "running" not in state:
                if "waiting" in state:
                    reason = state["waiting"].get("reason")
                    message = state["waiting"].get("message")
                    lines.append(YELLOW + f'pod {pod} is waiting: {reason}' + RESET)
                    lines.append(YELLOW + f'\t{message}' + RESET)
                if "terminated" in state:
                    reason = state["terminated"].get("reason")
                    message = state["terminated"].get("message")
                    lines.append(RED + f'pod {pod} is terminated: {reason}' + RESET)
                    lines.append(RED + f'\t{message}' + RESET)
            restartCount = container.get("restartCount", 0)
            if restartCount != 0:
                lines.append(RED + f'pod {pod} has restarted {restartCount} times' + RESET)
    debug(f'deployment/{dc}: pod/{pod}: got flavor {lines}')
    return lines


if __name__ == '__main__':
    main()
