#!/usr/bin/env python

import json
import os

import ruamel.yaml as yaml  # ruamel allows us to preserve formatting


def unify_job_properties(directory):
    jobs = load_jobs_from_directory(directory=directory)
    unify_jobs(jobs=jobs)


def load_jobs_from_directory(directory):
    jobs = []
    for filename in os.listdir(path=directory):
        if not filename.endswith('.yaml'):
            continue
        path = os.path.join(directory, filename)
        with open(path) as f:
            try:
                jobs.extend(load_jobs_from_stream(stream=f, path=path))
            except Exception as error:
                raise ValueError('failed to load jobs from {}'.format(path)) from error
    return jobs


def load_jobs_from_stream(stream, path):
    documents = list(yaml.safe_load_all(stream))
    if len(documents) != 1:
        raise ValueError('{} YAML documents; only one document is supported'.format(len(documents)))
    for job_type, type_data in documents[0].items():
        if job_type == 'periodics':
            for job in type_data:
                job['_path'] = path
                job['_type'] = job_type
                yield job
        else:  # presubmits, etc.
            for repo, jobs in type_data.items():
                for job in jobs:
                    job['_path'] = path
                    job['_type'] = job_type
                    job['_repo'] = repo
                    yield job


def unify_jobs(jobs, suspect_branches=None):
    if suspect_branches is None:
        suspect_branches = {'release-4.8', 'release-4.9'}
    for job in jobs:
        try:
            branch, _ = job_branch_context(job=job)
        except ValueError:
            continue
        if branch not in suspect_branches:
            continue  # master is a source of canonical data

        siblings = get_siblings(job=job, jobs=jobs, suspect_branches=suspect_branches)
        if not siblings:
            continue

        unify_job(job=job, siblings=siblings)


def job_branch_context(job):
    try:
        branch = job.get('branches', [])[0]
    except IndexError as error:
        raise ValueError('job has no branch') from error
    if branch.startswith('release-3.') or branch in {'release-4.1', 'release-4.2', 'release-4.3', 'release-4.4', 'release-4.5'}:
        raise ValueError('{} is ancient'.format(branch))

    context = job.get('context')
    if not context:
        raise ValueError('job has no context')

    return (branch, context)


def get_siblings(job, jobs, suspect_branches):
    try:
        branch, context = job_branch_context(job=job)
    except ValueError:
        return None

    siblings = {}
    for sibling in jobs:
        try:
            sibling_branch, sibling_context = job_branch_context(job=sibling)
        except ValueError:
            continue
        if sibling_branch in suspect_branches:
            continue
        if sibling_context == context and sibling_branch != branch:
            siblings[sibling_branch] = sibling
    return siblings


def unify_job(job, siblings, mutable_properties=None):
    if mutable_properties is None:
        # https://docs.ci.openshift.org/docs/how-tos/contributing-openshift-release/#tolerated-changes-to-generated-jobs
        mutable_properties = {
            'always_run',
            'max_concurrency',
            'optional',
            'reporter_config',
            'run_if_changed',
            'skip_if_only_changed',
            'skip_report',
        }
    branch, context = job_branch_context(job=job)

    updated = False
    for prop in mutable_properties:
        sibling_values = {json.dumps(sibling.get(prop), sort_keys=True) for sibling in siblings.values()}
        if len(sibling_values) > 1:
            print('cannot unify {} for {} {}.  Sibling values include:'.format(prop, branch, context))
            for sibling_branch, sibling in sorted(siblings.items()):
                print('  {}: {}'.format(sibling_branch, json.dumps(sibling.get(prop), sort_keys=True)))
        elif len(sibling_values) == 1:
            sibling_value = list(sibling_values)[0]
            value = json.dumps(job.get(prop), sort_keys=True)
            if value != sibling_value:
                print('{} {}: change {} from {} to {} to match siblings'.format(
                    branch, context, prop, value, sibling_value))
                job[prop] = json.loads(sibling_value)
                updated = True
    if updated:
        update_job(job=job)


def update_job(job):
    with open(job['_path']) as f:
        data = yaml.load(f, yaml.RoundTripLoader)
    if job['_type'] == 'periodics':
        jobs = data[job['_type']]
    else:
        jobs = data[job['_type']][job['_repo']]
    for i, j in enumerate(jobs):
        if j['name'] == job['name']:
            jobs[i] = {k: v for k,v in job.items() if not k.startswith('_')}
            break
    with open(job['_path'], 'w') as f:
        yaml.dump(data, f, default_flow_style=False, Dumper=yaml.RoundTripDumper)


if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(
        description='Unify 4.8 and 4.9 job configuration by adjusting mutable properties (optional, etc.) when they diverge from the master, 4.6, and 4.7 configuration.',
    )

    parser.add_argument(
        'dir',
        nargs='+',
        help='Path to a directory with job-configuration YAML, like ci-operator/jobs/$ORG/$REPO.',
    )

    args = parser.parse_args()

    for directory in args.dir:
        unify_job_properties(directory=directory)
