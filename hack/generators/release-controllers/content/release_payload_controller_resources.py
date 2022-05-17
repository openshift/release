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


def _cluster_level_rbac_resources(gendoc):
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
                    'verbs': ['get', 'list', 'watch', 'update']
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
    config = gendoc.context.config
    gendoc.add_comments("""These RBAC resources allow the release-payload-controller to update ReleasePayloads
    in the "ocp" namespace.""")
    gendoc.append_all([
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'Role',
            'metadata': {
                'name': 'release-payload-controller',
                'namespace': config.rpc_release_namespace
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
                'namespace': config.rpc_release_namespace
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


def _namespaced_rbac_resources(gendoc):
    _library_go_rbac(gendoc)
    _controller_rbac(gendoc)


def _deployment_resources(gendoc):
    context = gendoc.context

    gendoc.append({
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {
            'annotations': {
                'image.openshift.io/triggers': '[{"from":{"kind":"ImageStreamTag","name":"release-payload-controller:latest"},"fieldPath":"spec.template.spec.containers[?(@.name==\\"controller\\")].image"}]'
            },
            'name': 'release-payload-controller',
            'namespace': context.config.rc_deployment_namespace,
        },
        'spec': {
            'replicas': 1,
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
                                "requests": {
                                    "memory": "2Gi"
                                },
                            },
                            'command': [
                                '/usr/bin/release-payload-controller',
                                'start',
                                '--namespace=ci',
                                '-v=6',
                            ],
                            'image': 'release-payload-controller:latest',
                            'name': 'controller',
                        }
                    ],
                    'serviceAccountName': 'release-payload-controller',
                }
            }
        }
    })


def add_release_payload_controller_resources(config, context):
    with genlib.GenDoc(config.paths.path_rpc_resources.joinpath('admin_rbac.yaml'), context) as gendoc:
        _service_account(gendoc)
        _cluster_level_rbac_resources(gendoc)
        _namespaced_rbac_resources(gendoc)

    with genlib.GenDoc(config.paths.path_rpc_resources.joinpath('deployment.yaml'), context) as gendoc:
        _deployment_resources(gendoc)
