import genlib
from config import Context


def _release_admins_cluster_role(gendoc):
    gendoc.append({
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'ClusterRole',
        'metadata': {
            'name': 'openshift-release-admins'
        },
        'rules': [
            {
                'apiGroups': ['image.openshift.io'],
                'resources': [
                    'imagestreamimages',
                    'imagestreammappings',
                    'imagestreams',
                    'imagestreams/secrets',
                    'imagestreams/status',
                    'imagestreamtags',
                    'imagetags'
                ],
                'verbs': [
                    'create',
                    'delete',
                    'deletecollection',
                    'get',
                    'list',
                    'patch',
                    'update',
                    'watch'
                ]
            },
            {
                'apiGroups': ['image.openshift.io'],
                'resources': ['imagestreamimports'],
                'verbs': ['create']
            },
            {
                'apiGroups': ['image.openshift.io'],
                'resources': ['imagestreams/layers'],
                'verbs': [
                    'get',
                    'update',
                ]
            },
            {
                'apiGroups': ['release.openshift.io'],
                'resources': ['releasepayloads'],
                'verbs': [
                    'get',
                    'list',
                    'patch',
                    'update',
                    'watch'
                ]
            },
            {
                'apiGroups': ['config.openshift.io'],
                'resources': ['clusterversions'],
                'verbs': [
                    'get',
                    'list',
                    'watch'
                ]
            },
        ]
    })


def _add_release_admin_cluster_role_bindings(gendoc, namespace):
    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'openshift-release-admins-binding',
            'namespace': namespace,
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'ClusterRole',
            'name': 'openshift-release-admins'
        },
        'subjects': [{
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'openshift-release-admins'
        }]
    })


def _release_controller_developers_cluster_role(gendoc):
    gendoc.append({
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'ClusterRole',
        'metadata': {
            'name': 'openshift-release-controller-developers'
        },
        'rules': [
            {
                'apiGroups': ['release.openshift.io'],
                'resources': ['releasepayloads'],
                'verbs': [
                    'get',
                    'list',
                    'watch'
                ]
            },
        ]
    })


def _add_release_controller_developers_cluster_role_bindings(gendoc, namespace):
    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'openshift-release-controller-developers-binding',
            'namespace': namespace,
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'ClusterRole',
            'name': 'openshift-release-controller-developers'
        },
        'subjects': [{
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'openshift-release-controller-developers'
        }]
    })


def generate_release_admin_rbac(config):
    with genlib.GenDoc(config.paths.path_crt_resources.joinpath('admin_generated_rbac.yaml')) as gendoc:
        _release_admins_cluster_role(gendoc)
        _release_controller_developers_cluster_role(gendoc)

        for private in (False, True):
            for arch in config.arches:
                context = Context(config, arch, private)
                _add_release_admin_cluster_role_bindings(gendoc, context.is_namespace)
                _add_release_controller_developers_cluster_role_bindings(gendoc, context.is_namespace)
