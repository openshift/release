def generate_hypershift_admin_resources(gendoc):
    """Generate RBAC for HyperShift release controller in existing hypershift namespace"""
    # Create RBAC for release controller to manage imagestreams and releasepayloads
    gendoc.append_all([{
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'release-controller-modify',
            'namespace': 'hypershift'
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
                'verbs': ['get', 'list', 'watch', 'create', 'delete', 'update', 'patch']
            },
            {
                'apiGroups': ['release.openshift.io'],
                'resources': ['releasepayloads'],
                'verbs': ['get', 'list', 'watch', 'create', 'delete', 'update', 'patch']
            },
            {
                'apiGroups': [''],
                'resources': ['events'],
                'verbs': ['create', 'patch', 'update']
            }
        ]
    }, {
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'release-controller-binding',
            'namespace': 'hypershift'
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'release-controller-modify'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'release-controller',
            'namespace': 'ci'
        }]
    }])