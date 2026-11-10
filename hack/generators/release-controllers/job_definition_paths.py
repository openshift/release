"""
Shared access to core-services/release-controller/job-definition-paths.txt.

Used by both generate-release-controllers.py (for the git-sync sparse checkout)
and hack/validate-release-jobs.py, so they always agree on the list of
job definition directories.
"""

import os

PATHS_FILE = 'core-services/release-controller/job-definition-paths.txt'

# Prow plugin configuration, which the release-controller also reads.
PLUGIN_CONFIG_DIR = 'core-services/prow/02_config'


def read_job_definition_paths(repo_root):
    """Return the repo-relative job definition directories listed in PATHS_FILE."""
    path = os.path.join(repo_root, PATHS_FILE)
    dirs = []
    with open(path, 'r', encoding='utf-8') as f:
        for lineno, raw in enumerate(f, start=1):
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            where = f'{PATHS_FILE}:{lineno}: {line!r}'
            if line.startswith('/') or line.endswith('/'):
                raise ValueError(f'{where}: must not start or end with "/"')
            if '..' in line.split('/') or '.' in line.split('/') or '' in line.split('/'):
                raise ValueError(f'{where}: must not contain empty, "." or ".." components')
            if any(c in line for c in '*?[\\'):
                raise ValueError(f'{where}: must be a plain directory, not a glob pattern')
            if line in dirs:
                raise ValueError(f'{where}: duplicate entry')
            dirs.append(line)
    return dirs


def cone_sparse_checkout_patterns(dirs):
    """
    Return the cone-mode sparse-checkout patterns that check out each of the given
    directories recursively, plus the files directly inside each of their parents.
    The output matches what `git sparse-checkout set --cone <dirs>` writes, so
    git-sync's `git sparse-checkout init` (which defaults to cone mode) accepts it.
    """
    recursive = []
    for d in sorted(set(dirs)):
        if not any(d.startswith(r + '/') for r in recursive):
            recursive.append(d)

    parents = set()
    for d in recursive:
        parts = d.split('/')
        for i in range(1, len(parts)):
            parents.add('/'.join(parts[:i]))

    patterns = ['/*', '!/*/']
    for p in sorted(parents):
        patterns += [f'/{p}/', f'!/{p}/*/']
    patterns += [f'/{d}/' for d in recursive]
    return patterns
