#!/usr/bin/env python3

# Ignore dynamic imports
# pylint: disable=E0401, C0413

# Ignore large context objects
# pylint: disable=R0902, R0903

# All non-static methods in contexts
# pylint: disable=R0201

import logging
import sys
import pathlib
import glob
import os
import json

# Change python path so we can import genlib
sys.path.append(str(pathlib.Path(__file__).absolute().parent.parent.joinpath('lib')))
import genlib
sys.path.append(str(pathlib.Path(__file__).absolute().parents[0]))
import content

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger()


class Config:

    def __init__(self, releases_4x):
        self.rc_deployment_domain = 'apps.ci.l2s4.p1.openshiftapps.com'
        self.rc_release_domain = 'svc.ci.openshift.org'
        self.rc_deployment_namespace = 'ci'
        self.arches = ('x86_64', 's390x', 'ppc64le')
        self.releases_4x = releases_4x

    def get_arch_suffix(self, arch):
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


def run(git_clone_dir):
    releases_4x = []
    for name in glob.glob(f'{git_clone_dir}/ci-operator/config/openshift/origin/openshift-origin-release-4.*.yaml'):
        bn = os.path.splitext(os.path.basename(name))[0]  # e.g. openshift-origin-release-4.4
        major_minor = bn.split('-')[-1]  # 4.4
        releases_4x.append(major_minor)

    path_base = pathlib.Path(git_clone_dir)
    path_rc_deployments = path_base.joinpath('clusters/app.ci/release-controller')
    path_rc_release_resources = path_base.joinpath('core-services/release-controller')

    path_rc_build_configs = path_rc_release_resources
    path_rc_build_configs.mkdir(exist_ok=True)

    path_rc_annotations = path_rc_release_resources.joinpath('_releases')
    path_priv_rc_annotations = path_rc_annotations.joinpath('priv')  # location where priv release controller annotations are generated
    path_priv_rc_annotations.mkdir(exist_ok=True)

    releases_4x.sort()  # Glob does provide any guarantees on ordering, so force an order by sorting.
    config = Config(releases_4x)
    for private in (False, True):
        for arch in config.arches:
            context = Context(config, arch, private)

            with genlib.GenDoc(path_rc_deployments.joinpath(f'deploy-{context.is_namespace}-controller.yaml'), context) as gendoc:
                content.add_osd_rc_deployments(gendoc)

            with genlib.GenDoc(path_rc_release_resources.joinpath(f'admin_config_updater_rbac{context.suffix}.yaml'), context) as gendoc:
                content.add_art_namespace_config_updater_rbac(gendoc)

            with genlib.GenDoc(path_rc_release_resources.joinpath(f'admin_deploy-{context.is_namespace}-controller.yaml'), context) as gendoc:
                content.add_imagestream_namespace_rbac(gendoc)

            with genlib.GenDoc(path_rc_release_resources.joinpath(f'deploy-{context.is_namespace}-controller.yaml'), context) as gendoc:
                content.add_redirect_and_files_cache_resources(gendoc)

    with genlib.GenDoc(path_rc_deployments.joinpath('serviceaccount.yaml'), context=config) as gendoc:
        content.add_osd_rc_service_account_resources(gendoc)

    with genlib.GenDoc(path_rc_release_resources.joinpath('admin_deploy-ocp-publish-art.yaml'), context=config) as gendoc:
        content.add_art_publish(gendoc)

    with genlib.GenDoc(path_rc_build_configs.joinpath(f'ci-builder-images.yaml')) as gendoc_builders:
        with genlib.GenDoc(path_rc_build_configs.joinpath(f'ci-release-images.yaml')) as gendoc_release:
            with genlib.GenDoc(path_rc_build_configs.joinpath(f'ci-base-images.yaml')) as gendoc_base:
                for major_minor in releases_4x:
                    major, minor = major_minor.split('.')
                    content.add_golang_builders(gendoc_builders, clone_dir=git_clone_dir, major=major, minor=minor)
                    content.add_golang_release_builders(gendoc_release, clone_dir=git_clone_dir, major=major, minor=minor)
                    content.add_base_image_builders(gendoc_base, clone_dir=git_clone_dir, major=major, minor=minor)

    for major_minor in releases_4x:
        major, minor = major_minor.split('.')
        with genlib.GenDoc(path_rc_release_resources.joinpath(f'rpms-ocp-{major_minor}.yaml'), context) as gendoc:
            content.add_rpm_mirror_service(gendoc, git_clone_dir, major_minor)

        # If there is an annotation defined for the public release controller, use it as a template
        # for the private annotations.
        for annotation_path in path_rc_annotations.glob(f'release-ocp-*.json'):
            if annotation_path.name.endswith(('ci.json')):  # There are no CI annotations for the private controllers
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
            priv_annotation['message'] = "<!-- GENERATED FROM PUBLIC ANNOTATION CONFIG - DO NOT EDIT. -->" + priv_annotation['message']

            with path_priv_rc_annotations.joinpath(annotation_filename).open(mode='w+', encoding='utf-8') as f:
                json.dump(priv_annotation, f, sort_keys=True, indent=4)


if __name__ == '__main__':
    if len(sys.argv) < 2 or sys.argv[1] in ('--help', '-h', '-help'):
        print('Required parameter missing. Specify path to openshift/release clone directory.')
        exit(1)
    run(sys.argv[1])
