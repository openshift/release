
import genlib


def _add_origin_rbac(gendoc):
    gendoc.append({
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'release-controller-modify',
            'namespace': 'origin'
        },
        'rules': [
            {
                'apiGroups': [''],
                'resourceNames': ['release-upgrade-graph'],
                'resources': ['secrets'],
                'verbs': ['get', 'update', 'patch']
            },
            {
                'apiGroups': ['image.openshift.io'],
                'resources': ['imagestreams', 'imagestreamtags'],
                'verbs': ['get',
                          'list',
                          'watch',
                          'create',
                          'delete',
                          'update',
                          'patch']
            },
            {
                'apiGroups': [''],
                'resources': ['events'],
                'verbs': ['create', 'patch', 'update']
            }]
    })


def _add_origin_resources(gendoc):
    gendoc.append_all([
        {
            "apiVersion": "route.openshift.io/v1",
            "kind": "Route",
            "metadata": {
                "name": "release-controller",
                "namespace": "ci",
            },
            "spec": {
                "host": "origin-release.apps.ci.l2s4.p1.openshiftapps.com",
                "tls": {
                    "insecureEdgeTerminationPolicy": "Redirect",
                    "termination": "Edge"
                },
                "to": {
                    "kind": "Service",
                    "name": "release-controller",
                }
            }
        }, {
            "apiVersion": "v1",
            "kind": "Service",
            "metadata": {
                "name": "release-controller",
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
                    "app": "release-controller"
                }
            }
        }, {
            "apiVersion": "apps/v1",
            "kind": "Deployment",
            "metadata": {
                "annotations": {
                    "image.openshift.io/triggers": "[{\"from\":{\"kind\":\"ImageStreamTag\",\"name\":\"release-controller:latest\"},\"fieldPath\":\"spec.template.spec.containers[?(@.name==\\\"controller\\\")].image\"}]",
                },
                "name": "release-controller",
                "namespace": "ci",
            },
            "spec": {
                "replicas": 1,
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
                                "command": [
                                    "/usr/bin/release-controller",
                                    "--release-namespace=origin",
                                    "--prow-config=/etc/config/config.yaml",
                                    "--job-config=/etc/job-config",
                                    "--prow-namespace=ci",
                                    "--non-prow-job-kubeconfig=/etc/kubeconfig/kubeconfig",
                                    "--job-namespace=ci-release",
                                    "--tools-image-stream-tag=4.6:tests",
                                    "--release-architecture=amd64",
                                    "-v=4"
                                ],
                                "image": "release-controller:latest",
                                "name": "controller",
                                "volumeMounts": [
                                    {
                                        "mountPath": "/etc/config",
                                        "name": "config",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/job-config/misc",
                                        "name": "job-config-misc",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/job-config/master",
                                        "name": "job-config-master",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/job-config/3.x",
                                        "name": "job-config-3x",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/job-config/4.1",
                                        "name": "job-config-41",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/job-config/4.2",
                                        "name": "job-config-42",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/job-config/4.3",
                                        "name": "job-config-43",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/job-config/4.4",
                                        "name": "job-config-44",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/job-config/4.5",
                                        "name": "job-config-45",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/job-config/4.6",
                                        "name": "job-config-46",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/job-config/4.7",
                                        "name": "job-config-47",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/kubeconfig",
                                        "name": "release-controller-kubeconfigs",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/github",
                                        "name": "oauth",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/bugzilla",
                                        "name": "bugzilla",
                                        "readOnly": True
                                    },
                                    {
                                        "mountPath": "/etc/plugins",
                                        "name": "plugins",
                                        "readOnly": True
                                    }
                                ]
                            }
                        ],
                        "serviceAccountName": "release-controller",
                        "volumes": [
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "config"
                                },
                                "name": "config"
                            },
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "job-config-misc"
                                },
                                "name": "job-config-misc"
                            },
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "job-config-master"
                                },
                                "name": "job-config-master"
                            },
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "job-config-3.x"
                                },
                                "name": "job-config-3x"
                            },
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "job-config-4.1"
                                },
                                "name": "job-config-41"
                            },
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "job-config-4.2"
                                },
                                "name": "job-config-42"
                            },
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "job-config-4.3"
                                },
                                "name": "job-config-43"
                            },
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "job-config-4.4"
                                },
                                "name": "job-config-44"
                            },
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "job-config-4.5"
                                },
                                "name": "job-config-45"
                            },
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "job-config-4.6"
                                },
                                "name": "job-config-46"
                            },
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "job-config-4.7"
                                },
                                "name": "job-config-47"
                            },
                            {
                                "name": "release-controller-kubeconfigs",
                                "secret": {
                                    "defaultMode": 420,
                                    "items": [
                                        {
                                            "key": "sa.release-controller.app.ci.config",
                                            "path": "kubeconfig"
                                        }
                                    ],
                                    "secretName": "release-controller-kubeconfigs"
                                }
                            },
                            {
                                "name": "oauth",
                                "secret": {
                                    "defaultMode": 420,
                                    "secretName": "github-credentials-openshift-ci-robot"
                                }
                            },
                            {
                                "name": "bugzilla",
                                "secret": {
                                    "defaultMode": 420,
                                    "secretName": "bugzilla-credentials-openshift-bugzilla-robot"
                                }
                            },
                            {
                                "configMap": {
                                    "defaultMode": 420,
                                    "name": "plugins"
                                },
                                "name": "plugins"
                            }
                        ]
                    }
                }
            }
        }
    ])


def generate_origin_resources(context):
    config = context.config

    with genlib.GenDoc(config.paths.path_rc_deployments.joinpath('admin_deploy-origin-controller.yaml'), context) as gendoc:
        _add_origin_rbac(gendoc)

    with genlib.GenDoc(config.paths.path_rc_deployments.joinpath('deploy-origin-controller.yaml'), context) as gendoc:
        _add_origin_resources(gendoc)
