import genlib


def _service_account(gendoc):
    config = gendoc.context.config
    gendoc.append_all([
        {
            'apiVersion': 'v1',
            'kind': 'ServiceAccount',
            'metadata': {
                'name': 'release-reimport-controller',
                'namespace': config.rc_deployment_namespace,
            }
        }
    ])


def _cluster_scoped_rbac_resources(gendoc):
    config = gendoc.context.config
    gendoc.add_comments("""These cluster-level permissions are for the listers and watchers that are used throughout the
    release-reimport-controller.  The "infrastructures" permission is required by library-go to perform part of it's
    initialization.""")
    gendoc.append_all([
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRole',
            'metadata': {
                'name': 'release-reimport-controller',
            },
            'rules': [
                {
                    'apiGroups': ['image.openshift.io'],
                    'resources': ['imagestreams'],
                    'verbs': ['*']
                },
                {
                    'apiGroups': ['config.openshift.io'],
                    'resources': ['infrastructures'],
                    'verbs': ['get', 'list', 'watch']
                },
            ]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRoleBinding',
            'metadata': {
                'name': 'release-reimport-controller',
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'ClusterRole',
                'name': 'release-reimport-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-reimport-controller',
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
                'name': 'release-reimport-controller',
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
                'name': 'release-reimport-controller',
                'namespace': config.rc_deployment_namespace
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'Role',
                'name': 'release-reimport-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-reimport-controller'
            }]
        }
    ])


def _namespace_scoped_rbac_resources(gendoc):
    _library_go_rbac(gendoc)


def _namespace_list(namespaces):
    namespace_list = []
    for namespace in namespaces:
        namespace_list.append("--namespaces=" + namespace)
    return namespace_list


def _deployment_resources(gendoc, namespaces):
    context = gendoc.context

    gendoc.append_all([
        {
            'apiVersion': 'apps/v1',
            'kind': 'Deployment',
            'metadata': {
                'annotations': {
                    'image.openshift.io/triggers': '[{"from":{"kind":"ImageStreamTag","name":"release-reimport-controller:latest"},"fieldPath":"spec.template.spec.containers[?(@.name==\\"controller\\")].image"}]'
                },
                'name': 'release-reimport-controller',
                'namespace': context.config.rc_deployment_namespace,
            },
            'spec': {
                'replicas': 1,
                'selector': {
                    'matchLabels': {
                        'app': 'release-reimport-controller'
                    }
                },
                'template': {
                    'metadata': {
                        'labels': {
                            'app': 'release-reimport-controller'
                        }
                    },
                    'spec': {
                        'containers': [
                            {
                                "resources": {
                                    "limits": {
                                        "cpu": "500m",
                                        "memory": "4Gi"
                                    },
                                    "requests": {
                                        "cpu": "250m",
                                        "memory": "2Gi"
                                    },
                                },
                                'command': [
                                               '/usr/bin/release-reimport-controller',
                                               'start',
                                               '--dry-run',
                                               '-v=4',
                                           ] + _namespace_list(namespaces),
                                'image': 'release-reimport-controller:latest',
                                'name': 'controller',
                            }
                        ],
                        'serviceAccountName': 'release-reimport-controller',
                    }
                }
            }
        },
    ])


def add_release_reimport_controller_resources(config, context, namespaces):
    with genlib.GenDoc(config.paths.path_reimport_resources.joinpath('admin_rbac.yaml'), context) as gendoc:
        _service_account(gendoc)
        _cluster_scoped_rbac_resources(gendoc)
        _namespace_scoped_rbac_resources(gendoc)

    with genlib.GenDoc(config.paths.path_reimport_resources.joinpath('deployment.yaml'), context) as gendoc:
        _deployment_resources(gendoc, namespaces)
