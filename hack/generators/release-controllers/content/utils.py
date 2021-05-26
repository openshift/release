
def get_rc_volume_mounts(context):
    return [
        {
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
        *_get_dynamic_rc_volume_mounts(context),
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


def get_rc_volumes(context, namespace=None):
    suffix = ''
    if namespace is not None and len(namespace) > 0:
        suffix = f'-{namespace}'

    return [
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
        *_get_dynamic_deployment_volumes(context),
        {
            'name': 'release-controller-kubeconfigs',
            'secret': {
                'defaultMode': 420,
                'items': [{
                    'key': f'sa.release-controller{suffix}.app.ci.config',
                    'path': 'kubeconfig'
                }],
                'secretName': 'release-controller-kubeconfigs'
            }
        },
        {
            'name': 'oauth',
            'secret': {
                'defaultMode': 420,
                'secretName': 'github-credentials-openshift-merge-robot'
            }
        },
        {
            'name': 'bugzilla',
            'secret': {
                'defaultMode': 420,
                'secretName': 'bugzilla-credentials-openshift-bugzilla-robot'
            }
        },
        {
            'configMap': {
                'defaultMode': 420,
                'name': 'plugins'
            },
            'name': 'plugins'
        }]


def _get_dynamic_rc_volume_mounts(context):
    prow_volume_mounts = []

    for major_minor in context.config.releases:
        prow_volume_mounts.append({
            'mountPath': f'/etc/job-config/{major_minor}',
            'name': f'job-config-{major_minor.replace(".", "")}',  # e.g. job-config-45
            'readOnly': True
        })

    return prow_volume_mounts


def _get_dynamic_deployment_volumes(context):
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

    for major_minor in context.config.releases:
        prow_volumes.append({
            'configMap': {
                'defaultMode': 420,
                'name': f'job-config-{major_minor}'
            },
            'name': f'job-config-{major_minor.replace(".", "")}'
        })

    return prow_volumes
