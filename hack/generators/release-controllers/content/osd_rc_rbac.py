

def add_osd_rc_service_account_resources(gendoc):
    config = gendoc.context
    sa_annotations = {}
    for arch in config.arches:
        arch_priv_suffix = config.get_suffix(arch, private=True)
        sa_annotations[
            f'serviceaccounts.openshift.io/oauth-redirectreference.ocp{arch_priv_suffix}'] = '{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"release-controller-ocp%s"}}' % arch_priv_suffix

    gendoc.append_all([
        {
            'apiVersion': 'v1',
            'kind': 'ServiceAccount',
            'metadata': {
                'annotations': sa_annotations,
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
            'kind': 'ClusterRoleBinding',
            'metadata': {
                'name': 'release-controller-priv-oauth'
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'ClusterRole',
                'name': 'release-controller-priv-oauth'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-controller',
                'namespace': config.rc_deployment_namespace
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
