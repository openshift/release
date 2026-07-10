from content.utils import get_rc_volumes, get_rc_volume_mounts, get_rcapi_volumes, get_rcapi_volume_mounts


def generate_hypershift_resources(gendoc):
    """Generate HyperShift release controller deployment resources"""
    context = gendoc.context

    gendoc.append_all([
        {
            "apiVersion": "route.openshift.io/v1",
            "kind": "Route",
            "metadata": {
                "name": "release-controller-hypershift",
                "namespace": "ci",
            },
            "spec": {
                "host": "hypershift-release.apps.ci.l2s4.p1.openshiftapps.com",
                "tls": {
                    "insecureEdgeTerminationPolicy": "Redirect",
                    "termination": "edge"
                },
                "to": {
                    "kind": "Service",
                    "name": "release-controller-api-hypershift",
                }
            }
        }, {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {
                "name": "release-controller-hypershift",
                "namespace": "ci",
            },
            "spec": {
                "ports": [
                    {
                        "port": 80,
                        "targetPort": 8080
                    }
                ],
                "selector": {
                    "app": "release-controller-hypershift"
                }
            }
        }, {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {
                "name": "release-controller-api-hypershift",
                "namespace": "ci",
            },
            "spec": {
                "ports": [
                    {
                        "port": 80,
                        "targetPort": 8080
                    }
                ],
                "selector": {
                    "app": "release-controller-api-hypershift"
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
                "name": "release-controller-hypershift",
                "namespace": "ci",
            },
            "spec": {
                "replicas": 1,
                "selector": {
                    "matchLabels": {
                        "app": "release-controller-hypershift"
                    }
                },
                "template": {
                    "metadata": {
                        "labels": {
                            "app": "release-controller-hypershift"
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
                                    "--release-namespace=hypershift",
                                    "--prow-config=/etc/config/config.yaml",
                                    "--supplemental-prow-config-dir=/etc/config",
                                    "--job-config=/var/repo/release/ci-operator/jobs",
                                    "--prow-namespace=ci",
                                    "--job-namespace=ci-release",
                                    "--tools-image-stream-tag=release-controller-bootstrap:tools",
                                    "--release-architecture=amd64",
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
                        "serviceAccountName": "release-controller",
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
                "name": "release-controller-api-hypershift",
                "namespace": "ci",
            },
            "spec": {
                "replicas": 3,
                "selector": {
                    "matchLabels": {
                        "app": "release-controller-api-hypershift"
                    }
                },
                "template": {
                    "metadata": {
                        "labels": {
                            "app": "release-controller-api-hypershift"
                        }
                    },
                    "spec": {
                        "containers": [
                            {
                                "command": [
                                    "/usr/bin/release-controller-api",
                                    "--release-namespace=hypershift",
                                    "--prow-namespace=ci",
                                    "--job-namespace=ci-release",
                                    "--tools-image-stream-tag=release-controller-bootstrap:tools",
                                    "--release-architecture=amd64",
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
                        "serviceAccountName": "release-controller",
                        "volumes": get_rcapi_volumes(context, secret_name=context.secret_name_tls_api)
                    }
                }
            }
        }
    ])