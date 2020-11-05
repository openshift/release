# pylint: disable=R0801


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


from .osd_rc_deployments import add_osd_rc_deployments
from .osd_rc_rbac import add_osd_rc_service_account_resources
from .art_publish_permissions import add_art_publish
from .art_namespaces_config_updater import add_art_namespace_config_updater_rbac
from .art_namespaces_rbac import add_imagestream_namespace_rbac
from .redirect_and_files_cache_resources import add_redirect_and_files_cache_resources
from .art_rpm_mirroring_services import add_rpm_mirror_service
from .machine_os_content_promotions import add_machine_os_content_promoter
