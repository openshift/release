

def add_ibm_managed_control_plane_testing(gendoc):
    """
    IBM is migrating their managed control plane solution to use HyperShift.
    In order to test effectively, they need to be able to test against nightlies
    (ECs are not frequent enough). A non-expiring service account token is
    provided to allow them to pull.
    """

    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'ServiceAccount',
        'metadata': {
            'name': 'ibm-mcp-nightly-pull-integration',
            'namespace': 'ocp'
        }
    })

    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'Secret',
        'metadata': {
            'name': 'ibm-mcp-nightly-pull-integration-secret',
            'namespace': 'ocp',
            'annotations': {
                'kubernetes.io/service-account.name': 'ibm-mcp-nightly-pull-integration'
            }
        },
        'type': 'kubernetes.io/service-account-token'
    }, comment='''IBM is migrating their managed control plane solution to use HyperShift.
In order to test effectively, they need to be able to test against nightlies
(ECs are not frequent enough). A non-expiring service account token is
provided to allow them to pull. Questions in forum-ibm-roks / https://redhat.enterprise.slack.com/archives/C015MKYUVSR''')

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'amd64-nightly-puller',
            'namespace': 'ocp'
        },
        'rules': [
            {
                'apiGroups': ['image.openshift.io'],
                'resources': ['imagestreams'],
                'verbs': ['get', 'list',],
                'resourceNames': ['release']
            },
            {
                'apiGroups': ['image.openshift.io'],
                'resources': ['imagestreams/layers'],
                'verbs': ['get'],
                'resourceNames': ['release']
            },
        ]
    }, comment='Allow pulling images from the AMD64 nightly release imagestream.')

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'ibm-mcp-nightly-pull-integration-secret-binding',
            'namespace': 'ocp'
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'amd64-nightly-puller'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'ibm-mcp-nightly-pull-integration',
            'namespace': 'ocp'
        }]
    })
