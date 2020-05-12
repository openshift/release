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
    dcs = run_oc(['get', 'deployment', '--selector', 'app=prow', '--output', 'jsonpath={.items[*].metadata.name}']).split()
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
            with open(log) as f:
                if sys.stdout.write(f.read()):
                    sys.stdout.write('\n')
        time.sleep(5)


def highlight(log_dir, dc):
    warn = '"level":"warning"'
    error = '"level":"error"'
    fatal = '"level":"fatal"'
    query = '"query":"'
    log = '{}/{}.log'.format(log_dir, dc)
    while True:
        debug("deployment/{}: gathering info".format(dc))
        header = renderHeader(dc)
        lines = []
        log_lines = []
        for pod in run_oc(['get', 'pods', '--selector', 'component={}'.format(dc), '--output', 'jsonpath={.items[*].metadata.name}']).split():
            debug("deployment/{}: pod/{}: gathering info".format(dc, pod))
            lines.extend(renderFlavor(pod, dc))
            cmd = ['logs', '--since', '20m', 'pod/{}'.format(pod)]
            if dc == 'deck-internal':
                cmd += ['--container', 'deck']
            if dc == 'boskos':
                cmd += ['--container', 'boskos']
            debug("deployment/{}: pod/{}: getting logs".format(dc, pod))
            try:
                for l in run_oc(cmd).splitlines():
                    if any(word in l for word in BLACKLIST):
                        continue
                    if query in l:
                        data = json.loads(l)
                        data.pop("query")
                        l = json.dumps(data)
                    if warn in l:
                        log_lines.append(YELLOW + l + RESET)
                    elif error in l or fatal in l:
                        log_lines.append(RED + l + RESET)
            except subprocess.CalledProcessError:
                debug("deployment/{}: pod/{}: getting logs failed".format(dc, pod))

        if not log_lines and not lines:
            header = "{} {}{}{}".format(header, GREEN, "OK", RESET)
        with open(log, 'w') as f:
            f.write('\n'.join([header, *lines, *log_lines[-5:]]))
        time.sleep(60)


def renderHeader(dc):
    debug("deployment/{}: rendering header".format(dc))
    rawdc = json.loads(run_oc(['get', 'deployment/{}'.format(dc), '--output', 'json']))
    spec = rawdc.get("spec", {})
    status = rawdc.get("status", {})
    desired = spec.get("replicas", 0)
    current = status.get("replicas", 0)
    updated = status.get("updatedReplicas", 0)
    available = status.get("availableReplicas", 0)
    version = "<unknown-version>"
    containers = spec.get("template", {}).get("spec", {}).get("containers", [])
    for container in containers:
        if dc == "jenkins-dev-operator":
            container_name = "jenkins-operator"
        elif dc == "deck-internal":
            container_name = "deck"
        else:
            container_name = dc
        if container.get("name") == container_name:
            image = container.get("image", "")
            version = image.split(":")[-1]
    headerColor = ''
    if desired != current:
        headerColor = RED

    message = '{} at {} [{}/{}]'.format(dc, version, current, desired)
    if updated != desired:
        message += ' ({} stale replicas)'.format(desired - updated)
    if available != desired:
        message += ' ({} unavailable replicas)'.format(desired - available)
    header = '{}{}{}:{}'.format(BOLD, headerColor, message, RESET)
    debug("deployment/{}: got header {}".format(dc, header))
    return header


def renderFlavor(pod, dc):
    debug("deployment/{}: pod/{}: rendering flavor".format(dc, pod))
    lines = []
    raw = json.loads(run_oc(['get', 'pod/{}'.format(pod), '--output', 'json']))
    status = raw.get("status", {})
    phase = status.get("phase", "")
    if phase != "Running":
        reason = status.get("reason", "")
        message = status.get("message", "")
        color = YELLOW
        if phase in ["Failed", "Unknown", "CrashLoopBackOff"]:
            color = RED
        lines.append(color + "pod {} is {}: {}, {}".format(pod, phase, reason, message))

    for container in status.get("containerStatuses", []):
        debug("pod/{}: handling status for container {}".format(pod, container.get("name", "")))
        if container.get("name") == dc:
            state = container.get("state", {})
            if "running" not in state:
                if "waiting" in state:
                    reason = state["waiting"].get("reason")
                    message = state["waiting"].get("message")
                    lines.append(YELLOW + "pod {} is waiting: {}".format(pod, reason) + RESET)
                    lines.append(YELLOW + "\t{}".format(message) + RESET)
                if "terminated" in state:
                    reason = state["terminated"].get("reason")
                    message = state["terminated"].get("message")
                    lines.append(RED + "pod {} is terminated: {}".format(pod, reason) + RESET)
                    lines.append(RED + "\t{}".format(message) + RESET)
            restartCount = container.get("restartCount", 0)
            if restartCount != 0:
                lines.append(RED + "pod {} has restarted {} times".format(pod, restartCount) + RESET)
    debug("deployment/{}: pod/{}: got flavor {}".format(dc, pod, lines))
    return lines


if __name__ == '__main__':
    main()
