import genlib
from config import Context


def _add_trt_admin_cluster_role_bindings(gendoc, namespace):
    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'trt-admins-binding',
            'namespace': namespace,
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'ClusterRole',
            'name': 'trt-admin'
        },
        'subjects': [{
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'trt-admins'
        }]
    })


def generate_trt_rbac(config):
    with genlib.GenDoc(config.paths.path_trt_resources.joinpath('admin_generated_rbac.yaml')) as gendoc:
        for private in (False, True):
            for arch in config.arches:
                context = Context(config, arch, private)
                _add_trt_admin_cluster_role_bindings(gendoc, context.is_namespace)

        gendoc.append({
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRoleBinding',
            'metadata': {
                'name': 'trt-cluster-admin-binding',
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'ClusterRole',
                'name': 'cluster-admin'
            },
            'subjects': [{
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'Group',
                'name': 'trt-admins'
            }]
        })
