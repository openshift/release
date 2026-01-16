# pylint: disable=R0902,R0903

import os
import pathlib


class RCPaths:
    def __init__(self, git_clone_dir):
        self.path_base = pathlib.Path(git_clone_dir)

        # These paths remained consistent through migration:
        self.path_ci_operator_config_release = self.path_base.joinpath('ci-operator/config/openshift/release')
        self.path_ci_operator_jobs_release = self.path_base.joinpath('ci-operator/jobs/openshift/release')

        # The original configuration and deployment files, to api.ci, are located here:
        self.path_rc_release_resources = self.path_base.joinpath('core-services/release-controller')

        self.path_rc_build_configs = self.path_rc_release_resources
        self.path_rc_build_configs.mkdir(exist_ok=True)

        self.path_rc_annotations = self.path_rc_release_resources.joinpath('_releases')
        self.path_priv_rc_annotations = self.path_rc_annotations.joinpath('priv')  # location where priv release controller annotations are generated
        self.path_priv_rc_annotations.mkdir(exist_ok=True)

        # The updated configuration and deployment files, to app.ci, are located here:
        self.path_rc_deployments = self.path_base.joinpath('clusters/app.ci/release-controller')
        self.path_rc_rpms = [
            self.path_base.joinpath('clusters/build-clusters/common/release-controller'),
            self.path_base.joinpath('clusters/build-clusters/vsphere02/release-controller'),
        ]

        # CRT Resources
        self.path_crt_resources = self.path_base.joinpath('clusters/app.ci/crt')

        # TRT Resources
        self.path_trt_resources = self.path_base.joinpath('clusters/app.ci/trt')

        # Release Payload Controller Resources
        self.path_rpc_resources = self.path_base.joinpath('clusters/app.ci/release-payload-controller')
        # Release Reimport Controller Resources
        self.path_reimport_resources = self.path_base.joinpath('clusters/app.ci/release-reimport-controller')
        # Release Mirror Cleanup Controller Resources
        self.path_mirror_cleanup_resources = self.path_base.joinpath('clusters/app.ci/release-mirror-cleanup-controller')


class Config:

    def __init__(self, git_clone_dir):
        self.rc_deployment_domain = 'apps.ci.l2s4.p1.openshiftapps.com'
        self.rc_release_domain = 'svc.ci.openshift.org'
        self.rc_deployment_namespace = 'ci'
        self.arches = ('x86_64', 's390x', 'ppc64le', 'arm64', 'multi')
        self.paths = RCPaths(git_clone_dir)
        self.releases = self._get_releases()
        self.scos_releases = self._get_scos_releases()
        self.rpc_release_namespace = "ocp"

    def _get_releases(self):
        releases = set()

        # Collect the 4.x and 5.x releases...
        for major in ('4', '5'):
            for name in self.paths.path_ci_operator_jobs_release.glob(f'openshift-release-release-{major}.*-periodics.yaml'):
                bn = os.path.splitext(os.path.basename(name))[0]  # e.g. openshift-release-release-4.4-periodics
                major_minor = bn.split('-')[-2]  # 4.4
                releases.add(major_minor)

        # Hardcoded releases to generate resources before periodics are established.
        # These can be removed once the corresponding periodics files exist.
        releases.add('4.23')
        releases.add('5.0')

        return sorted(releases)  # Glob does not provide any guarantees on ordering, so force an order by sorting.

    def _get_scos_releases(self):
        releases = []

        # SCOS support was introduced in 4.12
        for version in self.releases:
            if int(version.split('.')[1]) >= 12:
                releases.append(f'scos-{version}')

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

    def get_art_suffix(self, arch, private):
        suffix = '-art-latest'
        suffix += self.get_suffix(arch, private)
        return suffix


class Context:
    def __init__(self, config, arch, private):
        self.config = config
        self.arch = arch
        self.private = private

        self.suffix = config.get_suffix(arch, private)
        self.art_suffix = config.get_art_suffix(arch, private)
        self.jobs_namespace = f'ci-release{self.suffix}'
        self.rc_hostname = f'openshift-release{self.suffix}'
        self.rc_temp_hostname = f'openshift-release{self.suffix}-temp'
        self.hostname_artifacts = f'openshift-release-artifacts{self.suffix}'
        self.secret_name_tls = f'release-controller{self.suffix}-tls'
        self.secret_name_tls_api = f'release-controller-api{self.suffix}-tls'
        self.is_namespace = f'ocp{self.suffix}'
        self.rc_serviceaccount_name = f'release-controller-{self.is_namespace}'

        self.rc_service_name = f'release-controller-{self.is_namespace}'
        self.rc_api_service_name = f'release-controller-api-{self.is_namespace}'
        self.rc_route_name = self.rc_service_name

        # Routes on the api.ci cluster
        # files-cache
        self.fc_api_url = f'{self.hostname_artifacts}.{self.config.rc_release_domain}'

        # Routes on the app.ci cluster
        # release-controller
        self.rc_app_url = f'{self.rc_hostname}.{self.config.rc_deployment_domain}'
        # files-cache
        self.fc_app_url = f'{self.hostname_artifacts}.{self.config.rc_deployment_domain}'

    def get_supported_architecture_name(self):
        name = 'amd64'
        if self.arch not in ('amd64', 'x86_64'):
            name = self.arch
        return name
