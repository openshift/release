#!/usr/bin/env python3

# Ignore dynamic imports
# pylint: disable=E0401, C0413

# Ignore large context objects
# pylint: disable=R0902, R0903

# All non-static methods in contexts
# pylint: disable=R0201

# Allow TOOD
# pylint: disable=W0511

import logging
import sys
import pathlib
import os
import json
import argparse

# Change python path so we can import genlib
sys.path.append(str(pathlib.Path(__file__).absolute().parent.parent.joinpath('lib')))
import genlib
sys.path.append(str(pathlib.Path(__file__).absolute().parents[0]))
import content

logging.basicConfig(level=logging.INFO, format='[%(asctime)s:%(levelname)-7s] %(message)s')
logger = logging.getLogger()


class RCPaths:
    def __init__(self, git_clone_dir):
        self.path_base = pathlib.Path(git_clone_dir)
        self.path_rc_deployments = self.path_base.joinpath('clusters/app.ci/release-controller')
        self.path_rc_release_resources = self.path_base.joinpath('core-services/release-controller')

        self.path_rc_build_configs = self.path_rc_release_resources
        self.path_rc_build_configs.mkdir(exist_ok=True)

        self.path_rc_annotations = self.path_rc_release_resources.joinpath('_releases')
        self.path_priv_rc_annotations = self.path_rc_annotations.joinpath('priv')  # location where priv release controller annotations are generated
        self.path_priv_rc_annotations.mkdir(exist_ok=True)

        self.path_ci_operator_config_release = self.path_base.joinpath('ci-operator/config/openshift/release')
        self.path_ci_operator_jobs_release = self.path_base.joinpath('ci-operator/jobs/openshift/release')


class Config:

    def __init__(self, git_clone_dir):
        self.rc_deployment_domain = 'apps.ci.l2s4.p1.openshiftapps.com'
        self.rc_release_domain = 'svc.ci.openshift.org'
        self.rc_deployment_namespace = 'ci'
        self.arches = ('x86_64', 's390x', 'ppc64le')
        self.paths = RCPaths(git_clone_dir)
        self.releases = self._get_releases()

    def _get_releases(self):
        releases = []

        # Collect the 4.x releases...
        for name in self.paths.path_ci_operator_jobs_release.glob('openshift-release-release-4.*-periodics.yaml'):
            bn = os.path.splitext(os.path.basename(name))[0]  # e.g. openshift-release-release-4.4-periodics
            major_minor = bn.split('-')[-2]  # 4.4
            releases.append(major_minor)

        releases.sort()  # Glob does provide any guarantees on ordering, so force an order by sorting.
        return releases

    @staticmethod
    def get_arch_suffix(arch):
        suffix = ''
        if arch not in ('amd64', 'x86_64'):
            suffix += f'-{arch}'
        return suffix

    def get_suffix(self, arch, private):
        suffix = self.get_arch_suffix(arch)

        if private:
            suffix += '-priv'

        return suffix


class Context:
    def __init__(self, config, arch, private):
        self.config = config
        self.arch = arch
        self.private = private

        self.suffix = config.get_suffix(arch, private)
        self.jobs_namespace = f'ci-release{self.suffix}'
        self.rc_hostname = f'openshift-release{self.suffix}'
        self.hostname_artifacts = f'openshift-release-artifacts{self.suffix}'
        self.secret_name_tls = f'release-controller{self.suffix}-tls'
        self.is_namespace = f'ocp{self.suffix}'
        self.rc_serviceaccount_name = f'release-controller-{self.is_namespace}'

        self.rc_route_name = f'release-controller-{self.is_namespace}'
        self.rc_service_name = self.rc_route_name

        # Routes on the api.ci cluster
        # release-controller
        self.rc_api_url = f'{self.rc_hostname}.{self.config.rc_release_domain}'
        # files-cache
        self.fc_api_url = f'{self.hostname_artifacts}.{self.config.rc_release_domain}'

        # Routes on the app.ci cluster
        # release-controller
        self.rc_app_url = f'{self.rc_hostname}.{self.config.rc_deployment_domain}'
        # files-cache
        self.fc_app_url = f'{self.hostname_artifacts}.{self.config.rc_deployment_domain}'


def run(git_clone_dir, bump=False):

    config = Config(git_clone_dir)

    # Generate version specific files (if necessary)
    content.bump_versioned_resources(config, bump)

    for private in (False, True):
        for arch in config.arches:
            context = Context(config, arch, private)

            with genlib.GenDoc(config.paths.path_rc_deployments.joinpath(f'deploy-{context.is_namespace}-controller.yaml'), context) as gendoc:
                content.add_osd_rc_deployments(gendoc)
                content.add_osd_files_cache_service_account_resources(gendoc)
                content.add_osd_files_cache_resources(gendoc)

            with genlib.GenDoc(config.paths.path_rc_release_resources.joinpath(f'admin_config_updater_rbac{context.suffix}.yaml'), context) as gendoc:
                content.add_art_namespace_config_updater_rbac(gendoc)

            with genlib.GenDoc(config.paths.path_rc_release_resources.joinpath(f'admin_deploy-{context.is_namespace}-controller.yaml'), context) as gendoc:
                content.add_imagestream_namespace_rbac(gendoc)

            with genlib.GenDoc(config.paths.path_rc_release_resources.joinpath(f'deploy-{context.is_namespace}-controller.yaml'), context) as gendoc:
                content.add_redirect_resources(gendoc)

    with genlib.GenDoc(config.paths.path_rc_deployments.joinpath('serviceaccount.yaml'), context=config) as gendoc:
        content.add_osd_rc_service_account_resources(gendoc)

    with genlib.GenDoc(config.paths.path_rc_release_resources.joinpath('admin_deploy-ocp-publish-art.yaml'), context=config) as gendoc:
        content.add_art_publish(gendoc)

    with genlib.GenDoc(config.paths.path_rc_deployments.joinpath('admin_deploy-ocp-publish-art.yaml'), context=config) as gendoc:
        content.add_art_publish(gendoc)

    with genlib.GenDoc(config.paths.path_rc_release_resources.joinpath('rpms-ocp-3.11.yaml'), context=config) as gendoc:
        content.add_rpm_mirror_service(gendoc, git_clone_dir, '3.11')

    for major_minor in config.releases:
        with genlib.GenDoc(config.paths.path_rc_release_resources.joinpath(f'rpms-ocp-{major_minor}.yaml'), context=config) as gendoc:
            content.add_rpm_mirror_service(gendoc, git_clone_dir, major_minor)

        # If there is an annotation defined for the public release controller, use it as a template
        # for the private annotations.
        for annotation_path in config.paths.path_rc_annotations.glob('release-ocp-*.json'):
            if annotation_path.name.endswith('ci.json'):  # There are no CI annotations for the private controllers
                continue
            if '-stable' in annotation_path.name:  # There are no stable streams in private release controllers
                continue
            annotation_filename = os.path.basename(annotation_path)
            with open(annotation_path, mode='r', encoding='utf-8') as f:
                pub_annotation = json.load(f)
            print(str(annotation_path))
            priv_annotation = dict(pub_annotation)
            priv_annotation['name'] += '-priv'
            priv_annotation['mirrorPrefix'] += '-priv'
            priv_annotation['to'] += '-priv'
            priv_annotation.pop('check', None)  # Don't worry about the state of other releases
            priv_annotation.pop('publish', None)  # Don't publish these images anywhere
            priv_annotation.pop('periodic', None)  # Don't configure periodics
            priv_annotation['message'] = "<!-- GENERATED FROM PUBLIC ANNOTATION CONFIG - DO NOT EDIT. -->" + priv_annotation['message']
            for _, test_config in priv_annotation['verify'].items():
                test_config['prowJob']['name'] += '-priv'
                # TODO: Private jobs are disabled until the -priv variants can be generated by prowgen
                test_config['disabled'] = True

            with config.paths.path_priv_rc_annotations.joinpath(annotation_filename).open(mode='w+', encoding='utf-8') as f:
                json.dump(priv_annotation, f, sort_keys=True, indent=4)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Release Controller Configuration Generator')
    parser.add_argument('-b', '--bump', help='Create configuration for the next release (4.x+1).', action='store_true')
    parser.add_argument('-v', '--verbose', help='Enable verbose output.', action='store_true')
    parser.add_argument('clone_dir', help='Specify path to openshift/release clone directory.')

    args = parser.parse_args()

    if args.verbose:
        logger.setLevel(logging.DEBUG)

    run(args.clone_dir, args.bump)
