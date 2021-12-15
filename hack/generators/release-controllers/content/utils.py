
def get_rc_volume_mounts():
    return [
        {
            'mountPath': '/etc/config',
            'name': 'config',
            'readOnly': True
        },
        {
            'mountPath': '/etc/job-config',
            'name': 'job-config',
            'readOnly': True
        },
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
            'name': 'job-config',
            'projected': {
                'sources': [
                    {
                        'configMap': {
                            'name': 'job-config-misc'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-master-periodics'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-master-postsubmits'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-master-presubmits'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-3.x'
                        }
                    },
                    *_get_dynamic_projected_deployment_volumes(context),
                ]
            }
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
