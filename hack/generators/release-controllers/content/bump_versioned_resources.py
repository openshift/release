
import glob

from os import path
from shutil import copyfile


def _get_previous_version(version):
    pieces = version.split('.')

    if len(pieces) > 2:
        print(f'Unable to determine previous version number from version: {version}')
        exit(1)

    pieces[1] = str(int(pieces[1])-1)

    return '.'.join(pieces)


def _get_next_version(version):
    pieces = version.split('.')

    if len(pieces) > 2:
        print(f'Unable to determine next version number from version: {version}')
        exit(1)

    pieces[1] = str(int(pieces[1])+1)

    return '.'.join(pieces)


def _read_update_write_file(original_file, new_file, original_str, new_str):
    with open(original_file, "r") as f:
        data = f.read()

    with open(new_file, "w+") as f:
        f.write(data.replace(original_str, new_str))


def _bump_image_file(current_version, new_version, image_files_path):
    previous_file = image_files_path.joinpath(f'images-origin-{current_version}.yaml')
    new_file = image_files_path.joinpath(f'images-origin-{new_version}.yaml')

    if path.exists(previous_file) and not path.exists(new_file):
        _read_update_write_file(previous_file, new_file, current_version, new_version)


def _bump_repo_files(current_version, new_version, repo_files_path):
    for repo_file in glob.glob(f'{repo_files_path}/_repos/ocp-{current_version}-*.repo'):
        bn = path.basename(repo_file)
        new_repo_file = repo_files_path.joinpath(f'_repos/{bn.replace(current_version, new_version)}')

        if path.exists(repo_file) and not path.exists(new_repo_file):
            copyfile(repo_file, new_repo_file)


def _bump_ci_operator_config_files(current_version, new_version, config_files_path):
    previous_file = config_files_path.joinpath(f'openshift-release-master__ocp-{current_version}.yaml')
    new_file = config_files_path.joinpath(f'openshift-release-master__ocp-{new_version}.yaml')

    if path.exists(previous_file) and not path.exists(new_file):
        _read_update_write_file(previous_file, new_file, current_version, new_version)


def _bump_ci_operator_job_files(current_version, new_version, job_files_path, do_bump=False):
    previous_file = job_files_path.joinpath(f'openshift-release-release-{current_version}-periodics.yaml')
    new_file = job_files_path.joinpath(f'openshift-release-release-{new_version}-periodics.yaml')

    # This handles the 4.x to 4.(x+1)
    if (path.exists(previous_file) and not path.exists(new_file)) or do_bump:
        _read_update_write_file(previous_file, new_file, current_version, new_version)

        # This list holds the tuples that will ultimately roll all the versions forward for the previous 3 releases
        # [(4.(x-1), 4.x), (4.(x-2), 4.(x-1)), (4.(x-3), 4.(x-2))]
        # i.e. If current_version='4.8' and new_version='4.9, then versions=[('4.7', '4.8'), ('4.6', '4.7'), ('4.5', '4.6')]
        versions = []

        for i in range(1, 4):
            ver = float(current_version) - (i/10)
            versions.append(('{:.2}'.format(ver), '{:.2}'.format((ver + .1))))

        for current, new in versions:
            _read_update_write_file(new_file, new_file, current, new)


def bump_versioned_resources(config, do_bump=False):
    current_version = config.releases[len(config.releases) - 1]
    new_version = current_version

    if do_bump:
        new_version = _get_next_version(current_version)
    else:
        current_version = _get_previous_version(current_version)

    _bump_image_file(current_version, new_version, config.paths.path_rc_release_resources)
    _bump_repo_files(current_version, new_version, config.paths.path_rc_release_resources)
    _bump_ci_operator_config_files(current_version, new_version, config.paths.path_ci_operator_config_release)
    _bump_ci_operator_job_files(current_version, new_version, config.paths.path_ci_operator_jobs_release, do_bump)

    if do_bump:
        config.releases.append(new_version)
