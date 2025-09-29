import genlib


def _service_account(gendoc):
    config = gendoc.context.config
    gendoc.append_all([
        {
            'apiVersion': 'v1',
            'kind': 'ServiceAccount',
            'metadata': {
                'name': 'release-mirror-cleanup-controller',
                'namespace': config.rc_deployment_namespace,
            }
        }
    ])


def _cluster_scoped_rbac_resources(gendoc):
    config = gendoc.context.config
    gendoc.add_comments("""These cluster-level permissions are for the listers and watchers that are used throughout the
    release-mirror-cleanup-controller.  The "infrastructures" permission is required by library-go to perform part of it's
    initialization.""")
    gendoc.append_all([
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRole',
            'metadata': {
                'name': 'release-mirror-cleanup-controller',
            },
            'rules': [
                {
                    'apiGroups': ['image.openshift.io'],
                    'resources': ['imagestreams'],
                    'verbs': ['get', 'list', 'watch']
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
                'name': 'release-mirror-cleanup-controller',
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'ClusterRole',
                'name': 'release-mirror-cleanup-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-mirror-cleanup-controller',
                'namespace': config.rc_deployment_namespace
            }]
        }
    ])


def _docker_credentials_rbac_resources(gendoc, namespace):
    config = gendoc.context.config

    gendoc.add_comments(f'These RBAC resources allow the release-mirror-cleanup-controller to read secrets in the {namespace} namespace.')
    gendoc.append_all([
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'Role',
            'metadata': {
                'name': 'release-mirror-cleanup-controller',
                'namespace': namespace
            },
            'rules': [
                {
                    'apiGroups': [''],
                    'resources': ['secrets'],
                    'verbs': ['get']
                },
            ]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'RoleBinding',
            'metadata': {
                'name': 'release-mirror-cleanup-controller',
                'namespace': namespace
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'Role',
                'name': 'release-mirror-cleanup-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-mirror-cleanup-controller',
                'namespace': config.rc_deployment_namespace
            }]
        },
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
                'name': 'release-mirror-cleanup-controller',
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
                'name': 'release-mirror-cleanup-controller',
                'namespace': config.rc_deployment_namespace
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'Role',
                'name': 'release-mirror-cleanup-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-mirror-cleanup-controller'
            }]
        }
    ])


def _namespace_scoped_rbac_resources(gendoc):
    _library_go_rbac(gendoc)
    _docker_credentials_rbac_resources(gendoc, gendoc.context.jobs_namespace)


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
                    'keel.sh/policy': 'force',
                    'keel.sh/matchTag': 'true',
                    'keel.sh/trigger': 'poll',
                    'keel.sh/pollSchedule': '@every 5m'
                },
                'name': 'release-mirror-cleanup-controller',
                'namespace': context.config.rc_deployment_namespace,
            },
            'spec': {
                'replicas': 1,
                'selector': {
                    'matchLabels': {
                        'app': 'release-mirror-cleanup-controller'
                    }
                },
                'template': {
                    'metadata': {
                        'labels': {
                            'app': 'release-mirror-cleanup-controller'
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
                                               '/usr/bin/release-mirror-cleanup-controller',
                                               'start',
                                               '-v=4',
                                               '--credentials-namespace=' + context.jobs_namespace,
                                           ] + _namespace_list(namespaces),
                                'image': 'quay-proxy.ci.openshift.org/openshift/ci:ci_release-mirror-cleanup-controller_latest',
                                'imagePullPolicy': 'Always',
                                'name': 'controller',
                            }
                        ],
                        'serviceAccountName': 'release-mirror-cleanup-controller',
                    }
                }
            }
        },
    ])


def add_release_mirror_cleanup_controller_resources(config, context, namespaces):
    with genlib.GenDoc(config.paths.path_mirror_cleanup_resources.joinpath('admin_rbac.yaml'), context) as gendoc:
        _service_account(gendoc)
        _cluster_scoped_rbac_resources(gendoc)
        _namespace_scoped_rbac_resources(gendoc)

    with genlib.GenDoc(config.paths.path_mirror_cleanup_resources.joinpath('deployment.yaml'), context) as gendoc:
        _deployment_resources(gendoc, namespaces)
