import genlib


def _service_account(gendoc):
    config = gendoc.context.config
    gendoc.append_all([
        {
            'apiVersion': 'v1',
            'kind': 'ServiceAccount',
            'metadata': {
                'name': 'release-payload-controller',
                'namespace': config.rc_deployment_namespace,
            }
        }
    ])


def _cluster_scoped_rbac_resources(gendoc):
    config = gendoc.context.config
    gendoc.add_comments("""These cluster-level permissions are for the listers and watchers that are used throughout the
    release-payload-controller.  The "infrastructures" permission is required by library-go to perform part of it's
    initialization.""")
    gendoc.append_all([
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRole',
            'metadata': {
                'name': 'release-payload-controller',
            },
            'rules': [
                {
                    'apiGroups': ['batch'],
                    'resources': ['jobs'],
                    'verbs': ['get', 'list', 'watch']
                },
                {
                    'apiGroups': ['config.openshift.io'],
                    'resources': ['infrastructures'],
                    'verbs': ['get', 'list', 'watch']
                },
                {
                    'apiGroups': ['image.openshift.io'],
                    'resources': ['imagestreams'],
                    'verbs': ['get', 'list', 'watch']
                },
                {
                    'apiGroups': ['prow.k8s.io'],
                    'resources': ['prowjobs'],
                    'verbs': ['get', 'list', 'watch']
                },
                {
                    'apiGroups': ['release.openshift.io'],
                    'resources': ['releasepayloads'],
                    'verbs': ['get', 'list', 'watch']
                }
            ]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRoleBinding',
            'metadata': {
                'name': 'release-payload-controller',
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'ClusterRole',
                'name': 'release-payload-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-payload-controller',
                'namespace': config.rc_deployment_namespace
            }]
        }
    ])


def _library_go_rbac(gendoc):
    config = gendoc.context.config
    gendoc.add_comments("""These RBAC resources are required by library-go, to operate, in the "ci" namespace.  The
    "configmaps" and "Events" are used for Leader Election.  The "pods" and "replicasets" are used for Owner References.""")
    gendoc.append_all([
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'Role',
            'metadata': {
                'name': 'release-payload-controller',
                'namespace': config.rc_deployment_namespace
            },
            'rules': [
                {
                    'apiGroups': [''],
                    'resources': ['configmaps'],
                    'verbs': ['create', 'get', 'list', 'watch', 'update']
                },
                {
                    'apiGroups': ['coordination.k8s.io'],
                    'resources': ['leases'],
                    'verbs': ['create', 'get', 'list', 'watch', 'update']
                },
                {
                    'apiGroups': [''],
                    'resources': ['events'],
                    'verbs': ['create']
                },
                {
                    'apiGroups': [''],
                    'resources': ['pods'],
                    'verbs': ['get', 'list', 'watch']
                },
                {
                    'apiGroups': ['apps'],
                    'resources': ['replicasets'],
                    'verbs': ['get', 'list', 'watch']
                },
            ]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'RoleBinding',
            'metadata': {
                'name': 'release-payload-controller',
                'namespace': config.rc_deployment_namespace
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'Role',
                'name': 'release-payload-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-payload-controller'
            }]
        }
    ])


def _controller_rbac(gendoc):
    # OCP Resources
    config = gendoc.context.config

    for private in (False, True):
        for arch in config.arches:
            namespace = f'{config.rpc_release_namespace}{config.get_suffix(arch, private)}'
            _namespaced_rbac_resources(gendoc, namespace)

    # OKD Resources
    _namespaced_rbac_resources(gendoc, 'origin')


def _namespaced_rbac_resources(gendoc, namespace):
    config = gendoc.context.config

    gendoc.add_comments(f'These RBAC resources allow the release-payload-controller to update ReleasePayloads in the {namespace} namespace.')
    gendoc.append_all([
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'Role',
            'metadata': {
                'name': 'release-payload-controller',
                'namespace': namespace
            },
            'rules': [
                {
                    'apiGroups': ['release.openshift.io'],
                    'resources': ['releasepayloads', 'releasepayloads/status'],
                    'verbs': ['get', 'list', 'watch', 'update']
                },
            ]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'RoleBinding',
            'metadata': {
                'name': 'release-payload-controller',
                'namespace': namespace
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'Role',
                'name': 'release-payload-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-payload-controller',
                'namespace': config.rc_deployment_namespace
            }]
        },
    ])


def _namespace_scoped_rbac_resources(gendoc):
    _library_go_rbac(gendoc)
    _controller_rbac(gendoc)


def _deployment_resources(gendoc):
    context = gendoc.context

    gendoc.append_all([
        {
            'apiVersion': 'apps/v1',
            'kind': 'Deployment',
            'metadata': {
                'annotations': {
                    'keel.sh/policy': 'force',
                    'keel.sh/matchTag': 'true',
                    'keel.sh/trigger': 'poll',
                    'keel.sh/pollSchedule': '@every 5m'
                },
                'name': 'release-payload-controller',
                'namespace': context.config.rc_deployment_namespace,
            },
            'spec': {
                'replicas': 3,
                'selector': {
                    'matchLabels': {
                        'app': 'release-payload-controller'
                    }
                },
                'template': {
                    'metadata': {
                        'labels': {
                            'app': 'release-payload-controller'
                        }
                    },
                    'spec': {
                        'containers': [
                            {
                                "resources": {
                                    "limits": {
                                        "cpu": "500m",
                                        "memory": "8Gi"
                                    },
                                    "requests": {
                                        "cpu": "250m",
                                        "memory": "2Gi"
                                    },
                                },
                                'command': [
                                    '/usr/bin/release-payload-controller',
                                    'start',
                                    '--namespace=ci',
                                    '-v=6',
                                ],
                                'image': 'quay-proxy.ci.openshift.org/openshift/ci:ci_release-payload-controller_latest',
                                'imagePullPolicy': 'Always',
                                'name': 'controller',
                            }
                        ],
                        'serviceAccountName': 'release-payload-controller',
                        'imagePullSecrets': [{
                            'name': 'registry-pull-credentials'
                        }],
                    }
                }
            }
        },
        {
            'apiVersion': 'policy/v1',
            'kind': 'PodDisruptionBudget',
            'metadata': {
                'name': 'release-payload-controller',
                'namespace': context.config.rc_deployment_namespace,
            },
            'spec': {
                'minAvailable': 1,
                'selector': {
                    'matchLabels': {
                        'app': 'release-payload-controller',
                    }
                }
            }
        }
    ])


def add_release_payload_controller_resources(config, context):
    with genlib.GenDoc(config.paths.path_rpc_resources.joinpath('admin_rbac.yaml'), context) as gendoc:
        _service_account(gendoc)
        _cluster_scoped_rbac_resources(gendoc)
        _namespace_scoped_rbac_resources(gendoc)

    with genlib.GenDoc(config.paths.path_rpc_resources.joinpath('deployment.yaml'), context) as gendoc:
        _deployment_resources(gendoc)
