
from .utils import get_rc_volumes, get_rc_volume_mounts


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
    context = gendoc.context

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
                                "volumeMounts": get_rc_volume_mounts(context)
                            }
                        ],
                        "serviceAccountName": "release-controller",
                        "volumes": get_rc_volumes(context, None)
                    }
                }
            }
        }
    ])


def generate_origin_admin_resources(gendoc):
    _add_origin_rbac(gendoc)


def generate_origin_resources(gendoc):
    _add_origin_resources(gendoc)
