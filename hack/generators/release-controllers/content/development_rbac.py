
def _add_namespace_read_only_rbac(gendoc, namespace):
    gendoc.append({
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'release-controller-developers-read-only',
            'namespace': namespace
        },
        'rules': [
            {
                'apiGroups': [''],
                'resourceNames': ['release-upgrade-graph'],
                'resources': ['secrets'],
                'verbs': ['get', 'list', 'watch']
            },
            {
                'apiGroups': ['image.openshift.io'],
                'resources': ['imagestreams', 'imagestreamtags'],
                'verbs': ['get', 'list', 'watch']
            }]
    })

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'release-controller-developers-read-only-binding',
            'namespace': namespace,
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'release-controller-developers-read-only'
        },
        'subjects': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'openshift-release-controller-developers'
        }
    })


def _add_deployment_monitoring_rbac(gendoc):
    context = gendoc.context

    gendoc.append({
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'release-controller-developers-monitoring',
            'namespace': context.config.rc_deployment_namespace
        },
        'rules': [
            {
                'apiGroups': [''],
                'resources': ['pods'],
                'verbs': ['get', 'list', 'watch']
            }]
    })

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'release-controller-developers-monitoring-binding',
            'namespace': context.config.rc_deployment_namespace,
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'release-controller-developers-monitoring'
        },
        'subjects': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'openshift-release-controller-developers'
        }
    })


def _add_cache_monitoring_rbac(gendoc):
    context = gendoc.context

    gendoc.append({
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'release-controller-developers-monitoring',
            'namespace': context.jobs_namespace
        },
        'rules': [
            {
                'apiGroups': ['batch/v1'],
                'resources': ['jobs'],
                'verbs': ['get', 'list', 'watch']
            },
            {
                'apiGroups': [''],
                'resources': ['pods/attach', 'pods/exec'],
                'verbs': ['create']
            },
            {
                'apiGroups': [''],
                'resources': ['pods'],
                'verbs': ['get', 'list', 'watch']
            }]
    })

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'release-controller-developers-monitoring-binding',
            'namespace': context.jobs_namespace,
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'release-controller-developers-monitoring'
        },
        'subjects': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'openshift-release-controller-developers'
        }
    })


def add_development_monitoring_rbac(gendoc):
    _add_deployment_monitoring_rbac(gendoc)
    _add_cache_monitoring_rbac(gendoc)


def add_development_rbac(gendoc, namespace):
    _add_namespace_read_only_rbac(gendoc, namespace)
