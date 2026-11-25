#!/usr/bin/env python3
# Script to facilitate executing Prow utilities that require information about
# a pull request.  Sets the following variables based on its arguments:
#
# - BASE_REF
# - BASE_SHA
# - PULL_NUMBER
# - PULL_SHA
# - PULL_AUTHOR
#
# and can be used for a single execution:
#
# $ ./pj_env.py openshift/release master 31415 'Pull Author' some_script.sh
#
# or sourced by the shell:
#
# $ . <(./pj_env.py openshift/release master 31415 'Pull Author')
# $ some_script.sh
# $ some_script.sh
# $ some_script.sh
import os
import shlex
import subprocess
import sys


def main():
    if len(sys.argv) < 4:
        print(
            'Usage: repo base_ref pull_number author [cmd...]',
            file=sys.stderr)
        sys.exit(1)
    repo, base_ref, pull_number, pull_author, *cmd = sys.argv[1:]
    refs = get_refs(repo, base_ref, pull_number)
    if refs is None:
        sys.exit(1)
    base_sha, pull_sha = refs
    var = {
        'BASE_REF': base_ref,
        'BASE_SHA': base_sha,
        'PULL_NUMBER': pull_number,
        'PULL_SHA': pull_sha,
        'PULL_AUTHOR': pull_author}
    if not cmd:
        for k, v in var.items():
            print(f'export {k}={shlex.quote(v)}')
    else:
        os.environ.update(var)
        sys.exit(subprocess.call(cmd))


def get_refs(repo, base_ref, pull_number):
    base_ref = f'refs/heads/{base_ref}'
    pull_number = f'refs/pull/{pull_number}/head'
    out = subprocess.check_output((
        'git', 'ls-remote',
        'https://github.com/' + repo,
        base_ref, pull_number))
    refs = dict(x.split('\t')[::-1] for x in out.decode('utf-8').splitlines())
    base_sha = refs.get(base_ref)
    pull_sha = refs.get(pull_number)
    if base_sha is None:
        print(f'Base ref {base_ref} not found', file=sys.stderr)
        return None
    if pull_sha is None:
        print(f'Pull request {pull_number} not found', file=sys.stderr)
        return None
    return base_sha, pull_sha


if __name__ == '__main__':
    main()
