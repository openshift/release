#!/bin/env python3
import glob
import multiprocessing.dummy as multiprocessing
import subprocess
import sys
import tempfile
import time


exec_cmd = lambda *cmd: subprocess.check_output(cmd).decode('utf-8')
RED = exec_cmd('tput', 'setaf', '1')
YELLOW = exec_cmd('tput', 'setaf', '3')
BOLD = exec_cmd('tput', 'bold')
RESET = exec_cmd('tput', 'sgr0')
CLEAR = exec_cmd('tput', 'clear')


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
        for log in glob.glob(logs):
            with open(log) as f:
                if sys.stdout.write(f.read()):
                    sys.stdout.write('\n\n')
        time.sleep(5)


def highlight(log_dir, dc):
    warn = '"level":"warning"'
    error = '"level":"error"'
    fatal = '"level":"fatal"'
    log = '{}/{}.log'.format(log_dir, dc)
    header = '{}{}:{}'.format(BOLD, dc, RESET)
    while True:
        lines = []
        for pod in exec_cmd(
                'oc', 'get', 'pods', '--namespace', 'ci',
                '--selector', 'component={}'.format(dc),
                '--output', 'jsonpath={.items[*].metadata.name}').split():
            cmd = [
                'oc', 'logs', '--namespace', 'ci', '--since', '20m',
                'pod/{}'.format(pod)]
            if pod.startswith('deck-internal'):
                cmd += ['--container', 'deck']
            for l in exec_cmd(*cmd).splitlines():
                if warn in l:
                    lines.append(YELLOW + l + RESET)
                elif error in l or fatal in l:
                    lines.append(RED + l + RESET)
        with open(log, 'w') as f:
            if lines:
                f.write('\n'.join([header, *lines[-3:]]))
        time.sleep(60)


if __name__ == '__main__':
    main()
