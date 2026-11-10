def add_release_payload_modifier_service_account(gendoc):
    resources = gendoc
    config = gendoc.context

    gendoc.add_comments("""This ServiceAccount will allow CI the ability to update release-payloads.""")
    resources.append({
        'apiVersion': 'v1',
        'kind': 'ServiceAccount',
        'metadata': {
            'name': 'release-payload-modifier',
            'namespace': config.rc_deployment_namespace,
        }
    })


def add_release_payload_modifier_rbac(gendoc):
    resources = gendoc
    context = gendoc.context

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'release-payload-modify',
            'namespace': context.is_namespace
        },
        'rules': [
            {
                'apiGroups': ['release.openshift.io'],
                'resources': ['releasepayloads'],
                'verbs': ['get',
                          'list',
                          'watch',
                          'update',
                          'patch']
            }]
    })

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'release-payload-modify-binding',
            'namespace': context.is_namespace,
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'release-payload-modify'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'release-payload-modifier',
            'namespace': context.config.rc_deployment_namespace
        }]
    })
