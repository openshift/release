def _add_hypershift_operator_namespace(gendoc):
    """Create the hypershift-operator namespace and basic RBAC"""
    gendoc.append_all([{
        'apiVersion': 'v1',
        'kind': 'Namespace',
        'metadata': {
            'annotations': {
                'argocd.argoproj.io/sync-options': 'Prune=false,Delete=confirm',
                'openshift.io/description': 'Published Release Images for HyperShift',
                'openshift.io/display-name': 'HyperShift Release'
            },
            'name': 'hypershift-operator'
        }
    }, {
        # Grant all authenticated users rights to pull images
        'kind': 'RoleBinding',
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'metadata': {
            'name': 'hypershift-operator-image-puller-binding',
            'namespace': 'hypershift-operator'
        },
        'roleRef': {
            'kind': 'ClusterRole',
            'apiGroup': 'rbac.authorization.k8s.io',
            'name': 'system:image-puller'
        },
        'subjects': [
            {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'Group',
                'name': 'system:authenticated'
            },
            {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'Group',
                'name': 'system:unauthenticated'
            }
        ]
    }, {
        # ServiceAccount for image pulling
        'kind': 'ServiceAccount',
        'apiVersion': 'v1',
        'metadata': {
            'name': 'image-puller',
            'namespace': 'hypershift-operator'
        }
    }, {
        # Grant ServiceAccount rights to pull images from hypershift namespace
        'kind': 'RoleBinding',
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'metadata': {
            'name': 'hypershift-operator-cross-namespace-puller-binding',
            'namespace': 'hypershift'
        },
        'roleRef': {
            'kind': 'ClusterRole',
            'apiGroup': 'rbac.authorization.k8s.io',
            'name': 'system:image-puller'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'namespace': 'hypershift-operator',
            'name': 'image-puller'
        }]
    }, {
        # Grant ServiceAccount rights to pull images from ocp namespace
        'kind': 'RoleBinding',
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'metadata': {
            'name': 'hypershift-operator-ocp-puller-binding',
            'namespace': 'ocp'
        },
        'roleRef': {
            'kind': 'ClusterRole',
            'apiGroup': 'rbac.authorization.k8s.io',
            'name': 'system:image-puller'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'namespace': 'hypershift-operator',
            'name': 'image-puller'
        }]
    }, {
        # Grant admins view access to the namespace
        'kind': 'RoleBinding',
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'metadata': {
            'name': 'hypershift-operator-viewer-binding',
            'namespace': 'hypershift-operator'
        },
        'roleRef': {
            'kind': 'ClusterRole',
            'apiGroup': 'rbac.authorization.k8s.io',
            'name': 'view'
        },
        'subjects': [{
            'kind': 'Group',
            'apiGroup': 'rbac.authorization.k8s.io',
            'name': 'hypershift-admins',
            'namespace': 'hypershift-operator'
        }]
    }, {
        # Grant admins full management rights to the namespace
        'kind': 'RoleBinding',
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'metadata': {
            'name': 'hypershift-operator-admins-binding',
            'namespace': 'hypershift-operator'
        },
        'roleRef': {
            'kind': 'ClusterRole',
            'apiGroup': 'rbac.authorization.k8s.io',
            'name': 'pull-secret-namespace-manager'
        },
        'subjects': [{
            'kind': 'Group',
            'apiGroup': 'rbac.authorization.k8s.io',
            'name': 'hypershift-hybridsre',
            'namespace': 'hypershift-operator'
        }]
    }])


def _add_hypershift_rbac(gendoc):
    """Add RBAC for release controller in hypershift-operator namespace"""
    gendoc.append_all([{
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'release-controller-modify',
            'namespace': 'hypershift-operator'
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
                'apiGroups': ['release.openshift.io'],
                'resources': ['releasepayloads'],
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
    }, {
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'release-controller-binding',
            'namespace': 'hypershift-operator',
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'release-controller-modify',
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'release-controller',
            'namespace': 'ci'
        }
        ]
    }])


def generate_hypershift_admin_resources(gendoc):
    """Generate admin resources including namespace and RBAC"""
    _add_hypershift_operator_namespace(gendoc)
    _add_hypershift_rbac(gendoc)