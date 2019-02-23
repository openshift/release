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

def debug(msg):
    if os.environ.get("DEBUG", "") == "true":
        print(msg)


def main():
    dcs = exec_cmd(
        'oc', 'get', 'deployment',
        '--namespace', 'ci', '--selector', 'app=prow',
        '--output', 'jsonpath={.items[*].metadata.name}').split()
    with tempfile.TemporaryDirectory() as log_dir:
        fs = [(display, log_dir), *((highlight, log_dir, x) for x in dcs)]
        with multiprocessing.Pool(len(fs)) as pool:
            pool.starmap(lambda f, *args: f(*args), fs)


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
    log = '{}/{}.log'.format(log_dir, dc)
    while True:
        debug("deployment/{}: gathering info".format(dc))
        header = renderHeader(dc)
        lines = []
        log_lines = []
        for pod in exec_cmd(
                'oc', 'get', 'pods', '--namespace', 'ci',
                '--selector', 'component={}'.format(dc),
                '--output', 'jsonpath={.items[*].metadata.name}').split():
            debug("deployment/{}: pod/{}: gathering info".format(dc, pod))
            lines.extend(renderFlavor(pod, dc))
            cmd = [
                'oc', 'logs', '--namespace', 'ci', '--since', '20m',
                'pod/{}'.format(pod)]
            if pod.startswith('deck-internal'):
                cmd += ['--container', 'deck']
            debug("deployment/{}: pod/{}: getting logs".format(dc, pod))
            for l in exec_cmd(*cmd).splitlines():
                if warn in l:
                    log_lines.append(YELLOW + l + RESET)
                elif error in l or fatal in l:
                    log_lines.append(RED + l + RESET)

        if not log_lines and not lines:
            header = header + " " + GREEN + "OK" + RESET
        with open(log, 'w') as f:
            f.write('\n'.join([header, *lines, *log_lines[-5:]]))
        time.sleep(60)


def renderHeader(dc):
    debug("deployment/{}: rendering header".format(dc))
    rawdc = json.loads(exec_cmd(
        'oc', 'get', 'deployment/{}'.format(dc),
        '--namespace', 'ci', '--output', 'json'))
    spec = rawdc.get("spec", {})
    status = rawdc.get("status", {})
    desired = spec.get("replicas", 0)
    current = status.get("replicas", 0)
    updated = status.get("updatedReplicas", 0)
    available = status.get("availableReplicas", 0)
    version = "<unknown-version>"
    containers = spec.get("template", {}).get("spec", {}).get("containers", [])
    for container in containers:
        if container.get("name", "") == dc:
            image = container.get("image", "")
            version = image[image.index(":")+1:]
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
    raw = json.loads(exec_cmd('oc', 'get', 'pod/{}'.format(pod),
                              '--namespace', 'ci', '--output', 'json'))
    for container in raw.get("status", {}).get("containerStatuses", []):
        debug("pod/{}: handling status for container {}".format(pod, container.get("name", "")))
        if container.get("name", "") == dc:
            state = container.get("state", {})
            if state.get("running", "") == "":
                waiting = state.get("waiting", "")
                if waiting != "":
                    reason = waiting.get("reason", "")
                    message = waiting.get("message", "")
                    lines.append(YELLOW + "pod {} is waiting: {}".format(pod, reason) + RESET)
                    lines.append(YELLOW + "\t{}".format(message) + RESET)
                terminated = state.get("terminated", "")
                if terminated != "":
                    reason = terminated.get("reason", "")
                    message = terminated.get("message", "")
                    lines.append(RED + "pod {} is terminated: {}".format(pod, reason) + RESET)
                    lines.append(RED + "\t{}".format(message) + RESET)
            restartCount = container.get("restartCount", 0)
            if restartCount != 0:
                lines.append(RED + "pod {} has restarted {} times".format(pod, restartCount) + RESET)
    debug("deployment/{}: pod/{}: got flavor {}".format(dc, pod, lines))
    return lines

if __name__ == '__main__':
    main()
