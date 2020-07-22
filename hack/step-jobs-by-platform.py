#!/usr/bin/env python3

import codecs
import json
import os
from urllib.request import urlopen

import yaml


def load_config(directory):
    _repo_config = {}
    for _basedir, _, _filenames in os.walk(directory):
        for _filename in _filenames:
            if not _filename.endswith('.yaml'):
                continue
            _path = os.path.join(_basedir, _filename)
            try:
                with open(_path, 'r') as f:
                    _config = yaml.safe_load(f)
            except:
                print('failed to load YAML from {}'.format(_path))
                raise
            if 'zz_generated_metadata' not in _config:
                continue
            _org_repo = '{org}/{repo}'.format(**_config['zz_generated_metadata'])
            if _org_repo not in _repo_config:
                _repo_config[_org_repo] = {}
            for _test in _config.get('tests', []):
                if 'cluster_profile' not in _test.get('steps', {}):
                    continue
                _job_name = 'pull-ci-{org}-{repo}-{branch}-{test_as}'.format(test_as=_test['as'], **_config['zz_generated_metadata'])
                _test['steps']['platform'] = cluster_profile_platform(cluster_profile=_test['steps']['cluster_profile'])
                _repo_config[_org_repo][_job_name] = _test['steps']
    return _repo_config


def platform_stripped_workflows(repo_config):
    _unstrippable = {}
    _stripped = {}
    for _jobs in repo_config.values():
        for _job, _steps in _jobs.items():
            _stripped_workflow = platform_stripped_workflow(workflow=_steps['workflow'], platform=_steps['platform'])
            if not _stripped_workflow:
                if _steps['workflow'] not in _unstrippable:
                    _unstrippable[_steps['workflow']] = {}
                if _steps['platform'] not in _unstrippable[_steps['workflow']]:
                    _unstrippable[_steps['workflow']][_steps['platform']] = set()
                _unstrippable[_steps['workflow']][_steps['platform']].add(_job)
                continue
            if _stripped_workflow not in _stripped:
                _stripped[_stripped_workflow] = {}
            _stripped[_stripped_workflow][_steps['platform']] = _steps['workflow']
    if _unstrippable:
        print('unable to determine platform-agnostic workflows for:')
        for _workflow, _platforms in sorted(_unstrippable.items()):
            print('  {}'.format(_workflow))
            for _platform, _jobs in sorted(_platforms.items()):
                _ellipsis = ''
                if len(_jobs) > 3:
                    _ellipsis = ', ...'
                print('    {} ({}{})'.format(_platform, ', '.join(sorted(_jobs)[:3]), _ellipsis))
    return _stripped


def yield_interesting_jobs(repo_config, balanceable_workflows):
    for _jobs in repo_config.values():
        for _job, _steps in _jobs.items():
            _stripped_workflow = platform_stripped_workflow(workflow=_steps['workflow'], platform=_steps['platform'])
            if _stripped_workflow in balanceable_workflows:
                yield _job


def cluster_profile_platform(cluster_profile):
    """Translate from steps.cluster_profile to workflow.as slugs."""
    if cluster_profile == 'azure4':
        return 'azure'
    if cluster_profile == 'packet':
        return 'metal'
    return cluster_profile


def platform_stripped_workflow(workflow, platform):
    _key = workflow.replace(platform, 'PLATFORM')
    if 'PLATFORM' in _key:
        return _key
    return None


def get_prow_job_counts(uri, interesting_jobs):
    with urlopen(uri) as response:
        _jobs = json.load(codecs.getreader('utf-8')(response))
    _counts = {}
    for _job in _jobs.get('items', []):
        _name = _job['spec']['job']
        if _name not in interesting_jobs:
            continue
        _counts[_name] = _counts.get(_name, 0) + 1
    return _counts


def print_counts(counts, job_steps, job_org_repos, stripped_workflows, platform_specific_repositories):
    print('{}\t{}\t{}\t{}\t{}'.format('count', 'platform', 'status', 'alternatives', 'job'))
    for _job, _count in sorted(counts.items(), key=lambda job_count: -job_count[1]):
        _steps = job_steps[_job]
        _stripped_workflow = platform_stripped_workflow(workflow=_steps['workflow'], platform=_steps['platform'])
        _alternative_platforms = sorted(key for key in stripped_workflows[_stripped_workflow].keys() if key != _steps['platform'])
        if _steps['platform'] not in _job:
            _status = 'balanceable'
        elif job_org_repos[_job] in platform_specific_repositories:
            continue
        else:
            _status = 'unknown'
        print('{}\t{}\t{}\t{}\t{}'.format(_count, _steps['platform'], _status, ','.join(_alternative_platforms), _job))


if __name__ == '__main__':
    _repo_config = load_config(directory=os.path.join('ci-operator', 'config', 'openshift'))
    platforms = set()
    _job_steps = {}
    _job_org_repos = {}
    for _org_repo, _jobs in _repo_config.items():
        for _job, _steps in _jobs.items():
            platforms.add(_steps['platform'])
            _job_steps[_job] = _steps
            _job_org_repos[_job] = _org_repo
    _stripped_workflows = platform_stripped_workflows(repo_config=_repo_config)
    _balanceable_workflows = {workflow for workflow, platforms in _stripped_workflows.items() if len(platforms) > 1}
    fixed_workflows = set(_stripped_workflows.keys()) - _balanceable_workflows
    if fixed_workflows:
        print('workflows which need alternative platforms to support balancing:')
        for _workflow in sorted(fixed_workflows):
            print('  {}'.format(list(_stripped_workflows[_workflow].values())[0]))
    _interesting_jobs = set(yield_interesting_jobs(repo_config=_repo_config, balanceable_workflows=_balanceable_workflows))
    _counts = get_prow_job_counts(uri='https://prow.svc.ci.openshift.org/prowjobs.js', interesting_jobs=_interesting_jobs)
    _platform_specific_repositories = {
        'openshift/cloud-credential-operator',
        'openshift/installer',
        'openshift/machine-config-operator',
    }
    print_counts(counts=_counts, job_steps=_job_steps, job_org_repos=_job_org_repos, stripped_workflows=_stripped_workflows, platform_specific_repositories=_platform_specific_repositories)
