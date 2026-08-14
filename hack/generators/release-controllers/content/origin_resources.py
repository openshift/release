from content.utils import get_rc_volumes, get_rc_volume_mounts, get_rcapi_volumes, get_rcapi_volume_mounts
from content.osd_rc_deployments import get_oc_env_vars, get_oc_prepare_container


def add_legacy_origin_deployments_scaled_down(gendoc):
    """Emit the old release-controller / release-controller-api deployments
    (the ones that pre-date the okd rename) with replicas: 0 so they are
    drained atomically when the new release-controller-okd resources land."""
    context = gendoc.context

    gendoc.append({
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "annotations": {
                'keel.sh/policy': 'force',
                'keel.sh/matchTag': 'true',
                'keel.sh/trigger': 'poll',
                'keel.sh/pollSchedule': '@every 5m'
            },
            "name": "release-controller",
            "namespace": context.config.rc_deployment_namespace,
        },
        "spec": {
            "replicas": 0,
            "selector": {
                "matchLabels": {
                    "app": "release-controller"
                }
            },
            "template": {
                "metadata": {
                    "labels": {
                        "app": "release-controller"
                    }
                },
                "spec": {
                    "containers": [
                        {
                            'image': 'quay-proxy.ci.openshift.org/openshift/ci:ci_release-controller_latest',
                            "name": "controller",
                        }
                    ],
                }
            }
        }
    })

    gendoc.append({
        "apiVersion": "apps/v1",
        "kind": "Deployment",
        "metadata": {
            "annotations": {
                'keel.sh/policy': 'force',
                'keel.sh/matchTag': 'true',
                'keel.sh/trigger': 'poll',
                'keel.sh/pollSchedule': '@every 5m'
            },
            "name": "release-controller-api",
            "namespace": context.config.rc_deployment_namespace,
        },
        "spec": {
            "replicas": 0,
            "selector": {
                "matchLabels": {
                    "app": "release-controller-api"
                }
            },
            "template": {
                "metadata": {
                    "labels": {
                        "app": "release-controller-api"
                    }
                },
                "spec": {
                    "containers": [
                        {
                            'image': 'quay-proxy.ci.openshift.org/openshift/ci:ci_release-controller-api_latest',
                            "name": "controller",
                        }
                    ],
                }
            }
        }
    })


def add_okd_deployments(gendoc):
    context = gendoc.context

    gendoc.append_all([
        {
            "apiVersion": "route.openshift.io/v1",
            "kind": "Route",
            "metadata": {
                "name": context.rc_route_name,
                "namespace": context.config.rc_deployment_namespace,
            },
            "spec": {
                "host": context.rc_app_url,
                "tls": {
                    "insecureEdgeTerminationPolicy": "Redirect",
                    "termination": "edge"
                },
                "to": {
                    "kind": "Service",
                    "name": context.rc_api_service_name,
                }
            }
        }, {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {
                "name": context.rc_service_name,
                "namespace": context.config.rc_deployment_namespace,
            },
            "spec": {
                "ports": [
                    {
                        "port": 80,
                        "targetPort": 8080
                    }
                ],
                "selector": {
                    "app": context.rc_service_name
                }
            }
        }, {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {
                "name": context.rc_api_service_name,
                "namespace": context.config.rc_deployment_namespace,
            },
            "spec": {
                "ports": [
                    {
                        "port": 80,
                        "targetPort": 8080
                    }
                ],
                "selector": {
                    "app": context.rc_api_service_name
                }
            }
        }, {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {
                "annotations": {
                    'keel.sh/policy': 'force',
                    'keel.sh/matchTag': 'true',
                    'keel.sh/trigger': 'poll',
                    'keel.sh/pollSchedule': '@every 5m'
                },
                "name": context.rc_service_name,
                "namespace": context.config.rc_deployment_namespace,
            },
            "spec": {
                "replicas": 1,
                "selector": {
                    "matchLabels": {
                        "app": context.rc_service_name
                    }
                },
                "template": {
                    "metadata": {
                        "labels": {
                            "app": context.rc_service_name
                        }
                    },
                    "spec": {
                        "initContainers": [
                            {
                                "name": "git-sync-init",
                                "command": ["/git-sync"],
                                "args": [
                                    "--repo=https://github.com/openshift/release.git",
                                    "--ref=main",
                                    "--root=/tmp/git-sync",
                                    "--one-time=true",
                                    "--depth=1"
                                ],
                                "env": [
                                    {
                                        "name": "GIT_SYNC_DEST",
                                        "value": "release"
                                    }
                                ],
                                "image": "quay-proxy.ci.openshift.org/openshift/ci:ci_git-sync_v4.3.0",
                                "volumeMounts": [
                                    {
                                        "name": "release",
                                        "mountPath": "/tmp/git-sync"
                                    }
                                ]
                            }
                        ],
                        "containers": [
                            {
                                "name": "git-sync",
                                "command": ["/git-sync"],
                                "args": [
                                    "--repo=https://github.com/openshift/release.git",
                                    "--ref=main",
                                    "--period=30s",
                                    "--root=/tmp/git-sync",
                                    "--max-failures=3"
                                ],
                                "env": [
                                    {
                                        "name": "GIT_SYNC_DEST",
                                        "value": "release"
                                    }
                                ],
                                "image": "quay-proxy.ci.openshift.org/openshift/ci:ci_git-sync_v4.3.0",
                                "volumeMounts": [
                                    {
                                        "name": "release",
                                        "mountPath": "/tmp/git-sync"
                                    }
                                ],
                                "resources": {
                                    "requests": {
                                        "memory": "1Gi",
                                        "cpu": "0.5",
                                    }
                                }
                            },
                            {
                                "command": [
                                    "/usr/bin/release-controller",
                                    f"--release-namespace={context.is_namespace}",
                                    "--prow-config=/etc/config/config.yaml",
                                    "--supplemental-prow-config-dir=/etc/config",
                                    "--job-config=/var/repo/release/ci-operator/jobs",
                                    f"--prow-namespace={context.config.rc_deployment_namespace}",
                                    f"--job-namespace={context.jobs_namespace}",
                                    "--tools-image-stream-tag=release-controller-bootstrap:tools",
                                    f"--release-architecture={context.get_supported_architecture_name()}",
                                    "-v=4",
                                    "--manifest-list-mode"
                                ],
                                'image': 'quay-proxy.ci.openshift.org/openshift/ci:ci_release-controller_latest',
                                'imagePullPolicy': 'Always',
                                "name": "controller",
                                "volumeMounts": get_rc_volume_mounts(),
                                'livenessProbe': {
                                    'httpGet': {
                                        'path': '/healthz',
                                        'port': 8081
                                    },
                                    'initialDelaySeconds': 3,
                                    'periodSeconds': 3,
                                },
                                'readinessProbe': {
                                    'httpGet': {
                                        'path': '/healthz/ready',
                                        'port': 8081
                                    },
                                    'initialDelaySeconds': 10,
                                    'periodSeconds': 3,
                                    'timeoutSeconds': 600,
                                },
                            }
                        ],
                        "serviceAccountName": context.rc_serviceaccount_name,
                        "volumes": get_rc_volumes(context)
                    }
                }
            }
        }, {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {
                "annotations": {
                    'keel.sh/policy': 'force',
                    'keel.sh/matchTag': 'true',
                    'keel.sh/trigger': 'poll',
                    'keel.sh/pollSchedule': '@every 5m'
                },
                "name": context.rc_api_service_name,
                "namespace": context.config.rc_deployment_namespace,
            },
            "spec": {
                "replicas": 3,
                "selector": {
                    "matchLabels": {
                        "app": context.rc_api_service_name
                    }
                },
                "template": {
                    "metadata": {
                        "labels": {
                            "app": context.rc_api_service_name
                        }
                    },
                    "spec": {
                        "initContainers": get_oc_prepare_container(),
                        "containers": [
                            {
                                "command": [
                                    "/usr/bin/release-controller-api",
                                    f"--release-namespace={context.is_namespace}",
                                    f"--prow-namespace={context.config.rc_deployment_namespace}",
                                    f"--job-namespace={context.jobs_namespace}",
                                    "--tools-image-stream-tag=release-controller-bootstrap:tools",
                                    f"--release-architecture={context.get_supported_architecture_name()}",
                                    "--enable-jira",
                                    "--jira-endpoint=https://redhat.atlassian.net",
                                    "--jira-username=openshift-release-controller-jira-bot@redhat.com",
                                    "--jira-password-file=/etc/jira/bot-password",
                                    "--release-qualifiers-config-path=/etc/qualifiers-config/release-qualifiers.yaml",
                                    "-v=4"
                                ],
                                'image': 'quay-proxy.ci.openshift.org/openshift/ci:ci_release-controller-api_latest',
                                'imagePullPolicy': 'Always',
                                "name": "controller",
                                "volumeMounts": get_rcapi_volume_mounts(),
                                "env": get_oc_env_vars(),
                                'livenessProbe': {
                                    'httpGet': {
                                        'path': '/healthz',
                                        'port': 8081
                                    },
                                    'initialDelaySeconds': 3,
                                    'periodSeconds': 3,
                                },
                                'readinessProbe': {
                                    'httpGet': {
                                        'path': '/healthz/ready',
                                        'port': 8081
                                    },
                                    'initialDelaySeconds': 10,
                                    'periodSeconds': 3,
                                    'timeoutSeconds': 600,
                                },
                            }
                        ],
                        "serviceAccountName": context.rc_serviceaccount_name,
                        "volumes": get_rcapi_volumes(context, secret_name=context.secret_name_tls_api)
                    }
                }
            }
        }
    ])
