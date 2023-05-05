def add_osd_rc_service_account_resources(gendoc):
    config = gendoc.context
    gendoc.append_all([
        {
            'apiVersion': 'v1',
            'kind': 'ServiceAccount',
            'metadata': {
                'name': 'release-controller',
                'namespace': config.rc_deployment_namespace,
            }
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'Role',
            'metadata': {
                'name': 'release-controller',
                'namespace': config.rc_deployment_namespace
            },
            'rules': [{
                'apiGroups': ['prow.k8s.io'],
                'resources': ['prowjobs'],
                'verbs': ['*']
            }, {
                'apiGroups': [''],
                'resourceNames': ['release-upgrade-graph'],
                'resources': ['secrets'],
                'verbs': ['get']
            }]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'RoleBinding',
            'metadata': {
                'name': 'release-controller',
                'namespace': config.rc_deployment_namespace
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'Role',
                'name': 'release-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-controller'
            }]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRole',
            'metadata': {
                'name': 'release-controller-priv-oauth'
            },
            'rules': [
                {
                    'apiGroups': ['authentication.k8s.io'],
                    'resources': ['tokenreviews'],
                    'verbs': ['create']
                },
                {
                    'apiGroups': ['authorization.k8s.io'],
                    'resources': ['subjectaccessreviews'],
                    'verbs': ['create']
                }]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRole',
            'metadata': {
                'name': 'files-cache-oauth-priv'
            },
            'rules': [
                {
                    'apiGroups': ['authentication.k8s.io'],
                    'resources': ['tokenreviews'],
                    'verbs': ['create']
                },
                {
                    'apiGroups': ['authorization.k8s.io'],
                    'resources': ['subjectaccessreviews'],
                    'verbs': ['create']
                }]
        },
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRole',
            'metadata': {
                'name': 'release-controller',
            },
            'rules': [
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
                'name': 'release-controller',
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'ClusterRole',
                'name': 'release-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-controller',
                'namespace': config.rc_deployment_namespace
            }]
        }
    ])

    gendoc.append_all(
        [
            {
                'apiVersion': 'v1',
                'kind': 'ServiceAccount',
                'metadata': {
                    'name': 'art-rc-query',
                    'namespace': config.rc_deployment_namespace,
                }
            },
            {
                'apiVersion': 'rbac.authorization.k8s.io/v1',
                'kind': 'Role',
                'metadata': {
                    'name': 'art-rc-query',
                    'namespace': 'ocp-private'
                },
                'rules': [{
                    'apiGroups': ['image.openshift.io'],
                    'resources': ['imagestreams'],
                    'verbs': ['get', 'list']
                }]
            },
            {
                'apiVersion': 'rbac.authorization.k8s.io/v1',
                'kind': 'RoleBinding',
                'metadata': {
                    'name': 'art-rc-query-binding',
                    'namespace': 'ocp-private'
                },
                'roleRef': {
                    'apiGroup': 'rbac.authorization.k8s.io',
                    'kind': 'Role',
                    'name': 'art-rc-query',
                },
                'subjects': [{
                    'kind': 'ServiceAccount',
                    'name': 'art-rc-query',
                    'namespace': config.rc_deployment_namespace,
                }]
            },
        ],
        comment="""
A service account to be used by ART to query data from the private release controllers. This account
may pass through the release-controller oauth proxy by virtue of its openshift-delegate-urls.
        """
    )
