#!/usr/bin/env python3

import glob
import json
import pathlib
import itertools
import sys
import logging

import yaml

# The purpose of this validation is to ensure that the private release controller configurations are kept
# up to date with the configuration of public release controllers.
# - If the public release controller calls out a verification prowJob X, the corresponding
#   core-services/release-controller/_releases/priv config must call out a prowJob named X-priv.
# - If X has a CI operator configuration in the release periodics, X-priv must also be defined in the
#   same file and:
#   - have "hidden: true"
#   - have "cron: @yearly"
#   - have a spec field that matches precisely the spec of X
# Note that private release controller prowJobs may be a superset of the corresponding public -- but the
# reverse will cause validation to fail.

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger()


def extract_prowjob_data(path_rc_config_dir):
    if not path_rc_config_dir.is_dir():
        raise IOError(f'Unable to find path: {str(path_rc_config_dir)}')

    rc_config_glob = glob.glob(f'{str(path_rc_config_dir)}/*.json')

    if not rc_config_glob:
        raise IOError(f'Did not find any release controller configurations (*.json) in {str(path_rc_config_dir)}')

    required_prowjobs = {}
    optional_prowjobs = {}

    for rc_config_file in rc_config_glob:
        logger.info('Checking release controller configuration file: %s', rc_config_file)

        if '-ci' in rc_config_file:
            logger.info('Skipping check as this is a CI release controller configuration')
            continue

        if '-origin' in rc_config_file:
            logger.info('Skipping check as this is an OKD release controller configuration')
            continue

        if '-stable' in rc_config_file:
            logger.info('Skipping check as this is a stable stream release controller configuration (stable does not exist in private)')
            continue

        with open(rc_config_file, mode='r', encoding='utf-8') as f:
            rc_config = json.load(f) or {}
            if 'verify' not in rc_config:
                continue
            for _, verify in rc_config['verify'].items():
                prowjob_name = verify['prowJob']['name']
                if 'optional' not in verify or verify['optional'] is False:
                    required_prowjobs[prowjob_name] = rc_config
                else:
                    optional_prowjobs[prowjob_name] = rc_config

    return required_prowjobs, optional_prowjobs

def run(git_clone_dir):

    path_base = pathlib.Path(git_clone_dir)
    path_rc_configs = path_base.joinpath('core-services/release-controller/_releases')
    path_priv_rc_configs = path_rc_configs.joinpath('priv')
    path_release_jobs = path_base.joinpath('ci-operator/jobs/openshift/release')

    priv_required_prowjobs, priv_optional_prowjobs = extract_prowjob_data(path_priv_rc_configs)
    pub_required_prowjobs, pub_optional_prowjobs = extract_prowjob_data(path_rc_configs)

    for pj_name in itertools.chain(priv_required_prowjobs.keys(), priv_optional_prowjobs):
        if not pj_name.endswith('-priv'):
            raise IOError(f'Prowjob ({pj_name}) in private release controller configuration is not suffixed with "-priv"')

    for pj_name, _ in pub_required_prowjobs.items():
        expected_priv_name = f'{pj_name}-priv'
        if expected_priv_name not in priv_required_prowjobs:
            raise IOError(f'A public release controller prowjob {pj_name} has no private analog {expected_priv_name} in {str(path_priv_rc_configs)}')

    for pj_name, _ in pub_optional_prowjobs.items():
        expected_priv_name = f'{pj_name}-priv'
        if expected_priv_name not in priv_optional_prowjobs:
            raise IOError(f'An optional public release controller prowjob {pj_name} has no private analog {expected_priv_name} in {str(path_priv_rc_configs)}')

    defined_prowjob_names = set()

    # Now look through the release prowjob definitions. Ensure:
    # - Every -priv job has "hidden: true"
    # - If a priv job has a corresponding public job, make sure the prowjob specs match.
    for filepath in itertools.chain(glob.glob(f'{str(path_release_jobs)}/*.yaml'), glob.glob('ci-operator/jobs/openshift/release/*.yml')):
        with open(filepath, mode='r', encoding='utf-8') as f:

            logger.info('Analyzing release controller job definitions: %s', filepath)

            defined_prowjob_specs = {}  # prowjob name => prowjob_spec
            jobs_def = yaml.safe_load(f)
            for job_type, job_list in jobs_def.items():  # e.g. job_type == 'periodic'

                if job_type != 'periodics':
                    logger.info('Skipping non periodic job definitions: %s', job_type)
                    continue

                for job_def in job_list:
                    job_name = job_def['name']
                    if job_name in defined_prowjob_names:
                        raise IOError(f'Prowjob name {job_name} is duplicated in {filepath}')
                    defined_prowjob_names.add(job_name)
                    defined_prowjob_specs[job_name] = job_def['spec']
                    if job_name.endswith('-priv'):
                        if 'cron' not in job_def or job_def['cron'] != '@yearly':
                            raise IOError('Private release jobs {job_name} must have "cron: \'@yearly\'"')
                        if 'hidden' not in job_def or not job_def['hidden']:
                            raise IOError(f'Private release job {job_name} is not marked with "hidden: true"')

            # Find all priv jobs and verify they match their corresponding pub job (^^ logic assumes these are
            # defined within the same file.
            for job_name, job_spec in defined_prowjob_specs.items():
                if job_name.endswith('-priv'):
                    pub_job_name = job_name[5:]  # strip -priv suffix
                    # Private jobs are a superset of public release jobs. So check if the private job has
                    # a corresponding public job.
                    if pub_job_name in defined_prowjob_specs:
                        pub_spec = defined_prowjob_specs[pub_job_name]
                        if pub_spec != job_spec:
                            raise IOError(f'Public ({pub_job_name}) and private ({job_name}) release prowjobs did not possess matching specs.')

    # Check that all required release controller prowjobs are actually defined
    for job_name in itertools.chain(pub_required_prowjobs.keys(), priv_required_prowjobs.keys()):
        if job_name not in defined_prowjob_names:
            raise IOError(f'Release controller configuration requires {job_name} but it is not defined in {str(path_release_jobs)}')

    for job_name, _ in pub_optional_prowjobs.items():
        expected_priv_name = f'{job_name}-priv'
        if job_name in defined_prowjob_names and expected_priv_name not in defined_prowjob_names:
            raise IOError(f'Release controller configuration has optional {job_name} but its private variation {expected_priv_name} is not defined in {str(path_release_jobs)}')


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Required parameter missing. Specify path to openshift/release clone directory.')
        exit(1)
    run(sys.argv[1])
