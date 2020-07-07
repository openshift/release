#!/usr/bin/env python3

import logging
import sys
import pathlib
import glob
import os
import yaml

logging.basicConfig(level=logging.DEBUG)
logger = logging.getLogger()


class Config(object):

    def __init__(self, releases_4x):
        self.rc_deployment_domain = 'apps.ci.l2s4.p1.openshiftapps.com'
        self.rc_release_domain = 'svc.ci.openshift.org'
        self.rc_deployment_namespace = 'ci'
        self.arches = ('x86_64', 's390x', 'ppc64le')
        self.releases_4x = releases_4x

    def get_suffix(self, arch, private):
        suffix = ''
        if arch not in ('amd64', 'x86_64'):
            suffix += f'-{arch}'

        if private:
            suffix += '-priv'

        return suffix


class Context(object):
    def __init__(self, config, arch, private):
        self.config = config
        self.arch = arch
        self.private = private

        self.suffix = config.get_suffix(arch, private)
        self.release_namespace = f'ocp{self.suffix}'
        self.jobs_namespace = f'ci-release{self.suffix}'
        self.hostname_rc = f'openshift-release{self.suffix}'
        self.hostname_artifacts = f'openshift-release-artifacts{self.suffix}'
        self.secret_name_tls = f'release-controller{self.suffix}-tls'


def get_osd_rc_route(context):
    return {
        'apiVersion': 'route.openshift.io/v1',
        'kind': 'Route',
        'metadata': {
            'name': f'release-controller-ocp{context.suffix}',
            'namespace': context.config.rc_deployment_namespace,
        },
        'spec': {
            'host': f'{context.hostname_rc}.{context.config.rc_deployment_domain}',
            'tls': {
                'insecureEdgeTerminationPolicy': 'Redirect',
                'termination': 'Reencrypt' if context.private else 'Edge'
            },
            'to': {
                'kind': 'Service',
                'name': f'release-controller-ocp{context.suffix}'
            }
        }
    }


def get_osd_rc_service(context):
    annotations = {}

    if context.private:
        annotations['service.alpha.openshift.io/serving-cert-secret-name'] = context.secret_name_tls

    return {
        'apiVersion': 'v1',
        'kind': 'Service',
        'metadata': {
            'name': f'release-controller-ocp{context.suffix}',
            'namespace': context.config.rc_deployment_namespace,
            'annotations': annotations,
        },
        'spec': {
            'ports': [{
                'port': 443 if context.private else 80,
                'targetPort': 8443 if context.private else 8080
            }],
            'selector': {
                'app': f'release-controller-ocp{context.suffix}'
            }
        }
    }


def get_dynamic_rc_volume_mounts(context):
    prow_volume_mounts = []

    for major_minor in context.config.releases_4x:
        prow_volume_mounts.append({
            'mountPath': f'/etc/job-config/{major_minor}',
            'name': f'job-config-{major_minor.replace(".", "")}',  # e.g. job-config-45
            'readOnly': True
        })

    return prow_volume_mounts


def get_dynamic_deployment_volumes(context):
    prow_volumes = []

    if context.private:
        prow_volumes.append({
            'name': 'internal-tls',
            'secret': {
                'secretName': context.secret_name_tls,
            }
        })
        prow_volumes.append({
            'name': 'session-secret',
            'secret': {
                # clusters/app.ci/release-controller/admin_deploy-ocp-controller-session-secret.yaml
                'secretName': 'release-controller-session-secret',
            }
        })

    for major_minor in context.config.releases_4x:
        prow_volumes.append({
            'configMap': {
                'defaultMode': 420,
                'name': f'job-config-{major_minor}'
            },
            'name': f'job-config-{major_minor.replace(".", "")}'
        })

    return prow_volumes


def get_osd_rc_deployment_sidecars(context):
    sidecars = list()

    if context.private:
        sidecars.append({
            'args': ['-provider=openshift',
                     '-https-address=:8443',
                     '-http-address=',
                     '-email-domain=*',
                     '-upstream=http://localhost:8080',
                     f'-client-id=system:serviceaccount:{context.config.rc_deployment_namespace}:release-controller',
                     '-openshift-ca=/etc/pki/tls/cert.pem',
                     '-openshift-ca=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
                     '-openshift-sar={"verb": "get", "resource": "imagestreams", "namespace": "ocp-private"}',
                     '-openshift-delegate-urls={"/": {"verb": "get", "resource": "imagestreams", "namespace": "ocp-private"}}',
                     '-client-secret-file=/var/run/secrets/kubernetes.io/serviceaccount/token',
                     '-cookie-secret-file=/etc/proxy/secrets/session_secret',
                     '-tls-cert=/etc/tls/private/tls.crt',
                     '-tls-key=/etc/tls/private/tls.key'],
            'image': 'openshift/oauth-proxy:latest',
            'imagePullPolicy': 'IfNotPresent',
            'name': 'oauth-proxy',
            'ports': [{
                'containerPort': 8443,
                'name': 'web'
            }],
            'volumeMounts': [{
                'mountPath': '/etc/tls/private',
                'name': 'internal-tls'
            },
                {
                    'mountPath': '/etc/proxy/secrets',
                    'name': 'session-secret'
                }]
        })
    return sidecars


def get_osd_rc_deployment(context):
    monitor_namespaces_args = [
        f'--release-namespace=ocp{context.suffix}',
    ]
    if not context.suffix:
        # The main x86_64 release controller also monitors origin
        monitor_namespaces_args.append('--release-namespace=origin')

    return {
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {
            'annotations': {
                'image.openshift.io/triggers': '[{"from":{"kind":"ImageStreamTag","name":"release-controller:latest"},"fieldPath":"spec.template.spec.containers[?(@.name==\\"controller\\")].image"}]'
            },
            'name': f'release-controller-ocp{context.suffix}',
            'namespace': context.config.rc_deployment_namespace,
        },
        'spec': {
            'replicas': 1,
            'selector': {
                'matchLabels': {
                    'app': f'release-controller-ocp{context.suffix}'
                }
            },
            'template': {
                'metadata': {
                    'labels': {
                        'app': f'release-controller-ocp{context.suffix}'
                    }
                },
                'spec': {
                    'containers': [
                        *get_osd_rc_deployment_sidecars(context),
                        {
                            'command': ['/usr/bin/release-controller',
                                        '--to=release',
                                        *monitor_namespaces_args,
                                        '--prow-config=/etc/config/config.yaml',
                                        '--job-config=/etc/job-config',
                                        f'--artifacts={context.hostname_artifacts}.{context.config.rc_release_domain}',
                                        '--listen=' + ('127.0.0.1:8080' if context.private else ':8080'),
                                        f'--prow-namespace={context.config.rc_deployment_namespace}',
                                        '--non-prow-job-kubeconfig=/etc/kubeconfig/kubeconfig',
                                        f'--job-namespace={context.jobs_namespace}',
                                        f'--tools-image-stream-tag=release-controller-bootstrap:tests',
                                        '-v=6',
                                        '--github-token-path=/etc/github/oauth',
                                        '--github-endpoint=http://ghproxy',
                                        '--github-graphql-endpoint=http://ghproxy/graphql',
                                        '--bugzilla-endpoint=https://bugzilla.redhat.com',
                                        '--bugzilla-api-key-path=/etc/bugzilla/api',
                                        '--plugin-config=/etc/plugins/plugins.yaml',
                                        '--verify-bugzilla'],
                            'image': 'release-controller:latest',
                            'name': 'controller',
                            'volumeMounts': [{
                                'mountPath': '/etc/config',
                                'name': 'config',
                                'readOnly': True
                            },
                                {
                                    'mountPath': '/etc/job-config/misc',
                                    'name': 'job-config-misc',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/etc/job-config/master',
                                    'name': 'job-config-master',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/etc/job-config/3.x',
                                    'name': 'job-config-3x',
                                    'readOnly': True
                                },
                                *get_dynamic_rc_volume_mounts(context),
                                {
                                    'mountPath': '/etc/kubeconfig',
                                    'name': 'release-controller-kubeconfigs',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/etc/github',
                                    'name': 'oauth',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/etc/bugzilla',
                                    'name': 'bugzilla',
                                    'readOnly': True
                                },
                                {
                                    'mountPath': '/etc/plugins',
                                    'name': 'plugins',
                                    'readOnly': True
                                }]
                        }],
                    'serviceAccountName': 'release-controller',
                    'volumes': [
                        {
                            'configMap': {
                                'defaultMode': 420,
                                'name': 'config'
                            },
                            'name': 'config'
                        },
                        {
                            'configMap': {
                                'defaultMode': 420,
                                'name': 'job-config-misc'
                            },
                            'name': 'job-config-misc'
                        },
                        {
                            'configMap': {
                                'defaultMode': 420,
                                'name': 'job-config-master'
                            },
                            'name': 'job-config-master'
                        },
                        {
                            'configMap': {
                                'defaultMode': 420,
                                'name': 'job-config-3.x'
                            },
                            'name': 'job-config-3x'
                        },
                        *get_dynamic_deployment_volumes(context),
                        {
                            'name': 'release-controller-kubeconfigs',
                            'secret': {
                                'items': [{
                                    'key': f'sa.release-controller-ocp{context.suffix}.api.ci.config',
                                    'path': 'kubeconfig'
                                }],
                                'secretName': 'release-controller-kubeconfigs'
                            }
                        },
                        {
                            'name': 'oauth',
                            'secret': {
                                'secretName': 'github-credentials-openshift-ci-robot'
                            }
                        },
                        {
                            'name': 'bugzilla',
                            'secret': {
                                'secretName': 'bugzilla-credentials-openshift-bugzilla-robot'
                            }
                        },
                        {
                            'configMap': {
                                'name': 'plugins'
                            },
                            'name': 'plugins'
                        }]
                }
            }
        }
    }


def get_osd_rc_resources(context):
    return [
        get_osd_rc_route(context),
        get_osd_rc_service(context),
        get_osd_rc_deployment(context),
    ]


def get_osd_rc_service_account(config):
    sa_annotations = {}
    for arch in config.arches:
        arch_priv_suffix = config.get_suffix(arch, True)
        sa_annotations[
            f'serviceaccounts.openshift.io/oauth-redirectreference.ocp{arch_priv_suffix}'] = '{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"release-controller-ocp%s"}}' % arch_priv_suffix

    return [
        {
            'apiVersion': 'v1',
            'kind': 'ServiceAccount',
            'metadata': {
                'annotations': sa_annotations,
                'name': 'release-controller',
                'namespace': config.rc_deployment_namespace,
            }
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'Role',
            'metadata': {
                'name': 'release-controller',
                'namespace': config.rc_deployment_namespace
            },
            'rules': [{
                'apiGroups': ['prow.k8s.io'],
                'resources': ['prowjobs'],
                'verbs': ['*']
            }]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'RoleBinding',
            'metadata': {
                'name': 'release-controller',
                'namespace': config.rc_deployment_namespace
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'Role',
                'name': 'release-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-controller'
            }]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRole',
            'metadata': {
                'name': 'release-controller-priv-oauth'
            },
            'rules': [{
                'apiGroups': ['authentication.k8s.io'],
                'resources': ['tokenreviews'],
                'verbs': ['create']
            },
                {
                    'apiGroups': ['authorization.k8s.io'],
                    'resources': ['subjectaccessreviews'],
                    'verbs': ['create']
                }]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRoleBinding',
            'metadata': {
                'name': 'release-controller-priv-oauth'
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'ClusterRole',
                'name': 'release-controller-priv-oauth'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-controller',
                'namespace': config.rc_deployment_namespace
            }]
        }
    ]


def run(git_clone_dir):
    releases_4x = []
    for filename in glob.glob(f'{git_clone_dir}/ci-operator/config/openshift/origin/openshift-origin-release-4.*.yaml'):
        bn = os.path.splitext(os.path.basename(filename))[0]  # e.g. openshift-origin-release-4.4
        major_minor = bn.split('-')[-1]  # 4.4
        releases_4x.append(major_minor)

    path_base = pathlib.Path(git_clone_dir)
    path_rc_deployments = path_base.joinpath('clusters/app.ci/release-controller')

    releases_4x.sort()
    config = Config(releases_4x)
    for arch in config.arches:
        context = Context(config, arch, False)
        with path_rc_deployments.joinpath(f'deploy-ocp{context.suffix}-controller.yaml').open(mode='w+') as out:
            yaml.dump_all(get_osd_rc_resources(context),
                          out,
                          default_flow_style=False)

        context = Context(config, arch, True)
        with path_rc_deployments.joinpath(f'deploy-ocp{context.suffix}-controller.yaml').open(mode='w+') as out:
            yaml.dump_all(get_osd_rc_resources(context),
                          out,
                          default_flow_style=False)

    with path_rc_deployments.joinpath('serviceaccount.yaml').open(mode='w+') as out:
        yaml.dump_all(get_osd_rc_service_account(config),
                      out,
                      default_flow_style=False)


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print('Required parameter missing. Specify path to openshift/release clone directory.')
        exit(1)

    run(sys.argv[1])
