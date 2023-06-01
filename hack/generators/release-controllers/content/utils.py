
def get_kubeconfig_volume_mounts():
    return [
        {
            'mountPath': '/etc/kubeconfigs',
            'name': 'release-controller-kubeconfigs',
            'readOnly': True
        }]


def get_rcapi_volume_mounts():
    return [
        {
            'mountPath': '/etc/kubeconfigs',
            'name': 'release-controller-kubeconfigs',
            'readOnly': True
        },
        {
            'mountPath': '/etc/jira',
            'name': 'jira',
            'readOnly': True
        }
    ]


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
            'mountPath': '/etc/github',
            'name': 'oauth',
            'readOnly': True
        },
        {
            'mountPath': '/etc/jira',
            'name': 'jira',
            'readOnly': True
        },
        {
            'mountPath': '/etc/plugins',
            'name': 'plugins',
            'readOnly': True
        }] + get_kubeconfig_volume_mounts()


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


def get_rcapi_volumes(context, secret_name=None):
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
        },
        {
            'name': 'jira',
            'secret': {
                'defaultMode': 420,
                'secretName': 'jira-credentials-openshift-jira-robot'
            }
        }
    ]

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
                            'name': 'job-config-main-periodics'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-master-postsubmits'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-main-postsubmits'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-master-presubmits'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-main-presubmits'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-1.x'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-2.x'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-3.x'
                        }
                    },
                    {
                        'configMap': {
                            'name': 'job-config-4.0'
                        }
                    },
                    *_get_dynamic_projected_deployment_volumes(context),
                ]
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
            'name': 'jira',
            'secret': {
                'defaultMode': 420,
                'secretName': 'jira-credentials-openshift-jira-robot'
            }
        },
        {
            'configMap': {
                'defaultMode': 420,
                'name': 'plugins'
            },
            'name': 'plugins'
        }] + get_kubeconfig_volumes(context, secret_name=context.secret_name_tls)


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
