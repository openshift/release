import yaml

from job_definition_paths import PLUGIN_CONFIG_DIR, cone_sparse_checkout_patterns, read_job_definition_paths

GIT_SYNC_SPARSE_CHECKOUT_CONFIGMAP = 'release-controller-sparse-checkout'
GIT_SYNC_SPARSE_CHECKOUT_ARG = '--sparse-checkout-file=/etc/git-sync/sparse-checkout'


class _LiteralString(str):
    pass


def _literal_string_representer(dumper, data):
    return dumper.represent_scalar('tag:yaml.org,2002:str', data, style='|')


yaml.add_representer(_LiteralString, _literal_string_representer, Dumper=yaml.SafeDumper)


def get_kubeconfig_volume_mounts():
    return [
        {
            'mountPath': '/etc/kubeconfigs',
            'name': 'release-controller-kubeconfigs',
            'readOnly': True
        }]


def get_git_sync_sparse_checkout_volume_mounts():
    return [
        {
            'name': 'sparse-checkout',
            'mountPath': '/etc/git-sync',
            'readOnly': True
        }]


def get_oc_volume_mounts():
    return [
        {
            'mountPath': '/tmp/home',
            'name': 'home',
        }, {
            'mountPath': '/tmp/git',
            'name': 'oc-cache',
        }, {
            'mountPath': '/tmp/home/.git-credentials',
            'name': 'git-credentials',
            'subPath': '.git-credentials'
        }, {
            'mountPath': '/tmp/pull-secret',
            'name': 'pull-secret'
        }
    ]


def get_rcapi_volume_mounts():
    return [
        {
            'mountPath': '/etc/jira',
            'name': 'jira',
            'readOnly': True
        },
        {
            'name': 'qualifiers-config',
            'mountPath': '/etc/qualifiers-config',
            'readOnly': True
        }
    ] + get_kubeconfig_volume_mounts() + get_oc_volume_mounts()


def get_rc_volume_mounts():
    return [
        {
            'mountPath': '/etc/config',
            'name': 'config',
            'readOnly': True
        },
        {
            'mountPath': '/var/repo',
            'name': 'release'
        },
        {
            'mountPath': '/etc/github',
            'name': 'oauth',
            'readOnly': True
        },
        {
            'mountPath': '/etc/jira',
            'name': 'jira',
            'readOnly': True
        }] + get_kubeconfig_volume_mounts() + get_oc_volume_mounts()


def get_kubeconfig_volumes(context, secret_name=None):
    if secret_name is None:
        secret_name = context.secret_name_tls

    return [
        *_get_dynamic_deployment_volumes(context, secret_name),
        {
            'name': 'release-controller-kubeconfigs',
            'secret': {
                'defaultMode': 420,
                'secretName': 'release-controller-kubeconfigs'
            }
        }]


def get_oc_volumes():
    return [
        {
            'name': 'home',
            'emptyDir': {}
        }, {
            'name': 'oc-cache',
            'emptyDir': {}
        }, {
            'name': 'git-credentials',
            'secret': {
                'defaultMode': 420,
                'secretName': 'release-controller-oc-git-credentials',
                'items': [{
                    'key': 'git_url_with_credentials',
                    'path': '.git-credentials'
                }]
            }
        }, {
            'name': 'pull-secret',
            'secret': {
                'defaultMode': 420,
                'secretName': 'release-controller-oc-pull-secret'
            }
        }
    ]


def get_rcapi_volumes(context, secret_name=None):
    if secret_name is None:
        secret_name = context.secret_name_tls

    return [
        {
            'name': 'jira',
            'secret': {
                'defaultMode': 420,
                'secretName': 'jira-credentials-openshift-jira-robot'
            }
        },
        {
            'name': 'qualifiers-config',
            'configMap': {
                'name': 'release-controller-release-qualifiers',
            }
        }
    ] + get_kubeconfig_volumes(context, secret_name) + get_oc_volumes()


def add_release_controller_sparse_checkout_configmap(gendoc, config):
    job_definition_paths = read_job_definition_paths(config.paths.path_base)
    patterns = cone_sparse_checkout_patterns(job_definition_paths + [PLUGIN_CONFIG_DIR])
    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'ConfigMap',
        'metadata': {
            'name': GIT_SYNC_SPARSE_CHECKOUT_CONFIGMAP,
            'namespace': config.rc_deployment_namespace,
        },
        'data': {
            'sparse-checkout': _LiteralString('\n'.join(patterns) + '\n'),
        },
    }, comment='Generated from core-services/release-controller/job-definition-paths.txt plus\nthe plugin config tree, in git\'s cone format so that git-sync\'s\n"git sparse-checkout init" (which defaults to cone mode) uses it as-is.')


def get_rc_volumes(context):
    return [
        {
            'configMap': {
                'defaultMode': 420,
                'name': 'config'
            },
            'name': 'config'
        },
        {
            'name': 'release',
            'emptyDir': {}
        },
        {
            'configMap': {
                'name': GIT_SYNC_SPARSE_CHECKOUT_CONFIGMAP
            },
            'name': 'sparse-checkout'
        },
        {
            'name': 'oauth',
            'secret': {
                'defaultMode': 420,
                'secretName': 'github-credentials-openshift-merge-robot'
            }
        },
        {
            'name': 'jira',
            'secret': {
                'defaultMode': 420,
                'secretName': 'jira-credentials-openshift-jira-robot'
            }
        }] + get_kubeconfig_volumes(context, secret_name=context.secret_name_tls) + get_oc_volumes()


def _get_dynamic_deployment_volumes(context, secret_name):
    prow_volumes = []

    if context.private:
        prow_volumes.append({
            'name': 'internal-tls',
            'secret': {
                'secretName': secret_name,
            }
        })
        prow_volumes.append({
            'name': 'session-secret',
            'secret': {
                # clusters/app.ci/release-controller/admin_deploy-ocp-controller-session-secret.yaml
                'secretName': 'release-controller-session-secret',
            }
        })

    return prow_volumes


def _get_dynamic_projected_deployment_volumes(context):
    prow_volumes = []

    for major_minor in context.config.releases:
        prow_volumes.append({
            'configMap': {
                'name': f'job-config-{major_minor}'
            }
        })
    return prow_volumes
