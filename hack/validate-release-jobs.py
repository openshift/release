#!/usr/bin/env python3

import sys
import argparse
import json
import logging
import os
import yaml

sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'generators', 'release-controllers'))
from job_definition_paths import PATHS_FILE, read_job_definition_paths  # pylint: disable=C0413

logging.basicConfig(format='[%(asctime)s] %(message)s')
logger = logging.getLogger('validate-release-jobs')
logger.setLevel(logging.INFO)

release_definition_path = 'core-services/release-controller/_releases'
presubmit_job = 'pull-ci-openshift-release-main-release-controller-config'
presubmit_jobs_file = 'ci-operator/jobs/openshift/release/openshift-release-main-presubmits.yaml'

# The release-controller's default aggregator job (sync_analysis.go:defaultAggregateProwJobName)
default_aggregate_prow_job_name = 'release-openshift-release-analysis-aggregator'


def raise_on_duplicates(ordered_pairs):
    d = {}
    for k, v in ordered_pairs:
        if k in d:
            raise ValueError(f'Duplicate key: {k} for value: {v}')
        d[k] = v
    return d


def read_release_definitions(path):
    definitions = {}
    for dirpath, _, filenames in os.walk(path):
        for filename in sorted(filenames):
            if filename.endswith('.json'):
                full_path = os.path.join(dirpath, filename)
                with open(full_path, 'r', encoding='utf-8') as release:
                    definitions.update({os.path.relpath(full_path, path): json.load(release, object_pairs_hook=raise_on_duplicates)})
    return definitions


def read_job_definitions(path):
    definitions = {}
    for dirpath, _, filenames in os.walk(path):
        for filename in sorted(filenames):
            if filename.endswith(('.yaml', '.yml')):
                full_path = os.path.join(dirpath, filename)
                with open(full_path, 'r', encoding='utf-8') as release:
                    definitions.update({full_path: yaml.load(release, Loader=yaml.SafeLoader)})
    return definitions


def get_job_data(release_definitions):
    data = []
    for release_name in release_definitions:
        release = release_definitions[release_name]
        for job_type in 'verify', 'upgrade', 'periodic':
            for release_verification_name, verification in (release.get(job_type) or {}).items():
                # The release-controller never launches disabled verify/upgrade jobs. Periodics have no
                # "disabled" field and are always launched, so they are always validated.
                if job_type != 'periodic' and verification.get('disabled', False):
                    continue
                data.append((release_name, release_verification_name, verification['prowJob']['name']))
                if 'aggregatedProwJob' in verification:
                    aggregator = (verification['aggregatedProwJob'] or {}).get('prowJob') or {}
                    data.append((release_name, release_verification_name, aggregator.get('name', default_aggregate_prow_job_name)))
    return data


def validate_jobs(data, definitions):
    missing = []
    for source, verification, name in data:
        logger.debug('Searching for job: %s', name)
        found = False
        for definition in definitions:
            for key in definition:
                jobs = definition[key]
                if jobs and 'periodics' in jobs:
                    logger.debug('\tChecking: %s', key)
                    for job in jobs['periodics']:
                        if job['name'] == name:
                            logger.debug('\t\tFound')
                            found = True
                            break
            if found:
                break
        if not found:
            missing.append((source, verification, name))
    return missing


def main(git_repo_path):
    job_definitions_paths = read_job_definition_paths(git_repo_path)
    missing_dirs = [p for p in job_definitions_paths if not os.path.isdir(os.path.join(git_repo_path, p))]
    for missing_dir in missing_dirs:
        logger.error('Job definition directory listed in %s does not exist: %s', PATHS_FILE, missing_dir)
    if missing_dirs:
        logger.error('''Either the directory name is wrong, or it is a new directory that must also be added as "./<dir>" to the
    sparse_checkout_files of the %s job in:
        %s''', presubmit_job, presubmit_jobs_file)
        sys.exit(1)

    releases = read_release_definitions(os.path.join(git_repo_path, release_definition_path))
    job_data = get_job_data(releases)
    job_definitions = []
    for job_definitions_path in job_definitions_paths:
        job_definition = read_job_definitions(os.path.join(git_repo_path, job_definitions_path))
        job_definitions.append(job_definition)
    missing_jobs = validate_jobs(job_data, job_definitions)

    for source, verification, name in missing_jobs:
        logger.error('Unable to locate job definition for: %s:%s:%s', source, verification, name)

    if len(missing_jobs) > 0:
        message = f'''If you are receiving this message, then there is a discrepancy in the release-controller\'s configuration:
    - If your PR has changes that have removed any of the aforementioned jobs, then you must also remove these jobs from the release-controller\'s configuration files under:
        core-services/release-controller/_releases, and then run a "make release-controllers" from the root of the repo.
    - If your PR has changes that have added any of the aforementioned jobs, then you must also ensure that these jobs have been defined in their respective location under:
        ci-operator/jobs
    - If your PR added a job in a new directory, then add that directory to:
        {PATHS_FILE}
      and then run a "make release-controllers" from the root of the repo so the
      release-controller git-sync sparse checkout includes it. Also add it as "./<dir>" to the
      sparse_checkout_files of the {presubmit_job} job in:
        {presubmit_jobs_file}
    - If you have no idea why you've received this error, then it's most likely do to another commit that introduced the problem.  Please reach out to #forum-ocp-crt in Slack.'''

        logger.error(message)

    sys.exit(1 if missing_jobs else 0)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Validate that the release verification/upgrade/periodic jobs exist.')
    parser.add_argument('-r', '--release-repo-path', help='Path to the openshift/release git repo.', required=True)
    parser.add_argument('-v', '--verbose', help='Enable verbose output.', action='store_true')

    opts = parser.parse_args()

    if opts.verbose:
        logger.setLevel(logging.DEBUG)

    if not os.path.exists(opts.release_repo_path):
        logger.error('Release repository path does not exist: %s', opts.release_repo_path)
        sys.exit(-1)
    elif not os.path.exists(os.path.join(opts.release_repo_path, 'hack', 'validate-release-jobs.py')):
        logger.error('Invalid release repository specified: %s', opts.release_repo_path)
        sys.exit(-1)

    main(opts.release_repo_path)
