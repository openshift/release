

def add_art_namespace_config_updater_rbac(gendoc):
    context = gendoc.context

    gendoc.append(
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'Role',
            'metadata': {
                'name': 'hook',
                'namespace': context.is_namespace,
            },
            'rules': [{
                'apiGroups': [''],
                'resources': ['configmaps'],
                'verbs': ['get', 'update', 'create']
            }]
        })

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'hook',
            'namespace': context.is_namespace,
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'hook',
            'namespace': context.is_namespace
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'hook',
            'namespace': context.config.rc_deployment_namespace,
        }]
    })

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'config-updater',
            'namespace': context.is_namespace
        },
        'rules': [
            {
                'apiGroups': ['apps'],
                'resources': ['deployments'],
                'verbs': ['get', 'create', 'update', 'patch']
            },
            {
                'apiGroups': ['route.openshift.io'],
                'resources': ['routes'],
                'verbs': ['get', 'create', 'update', 'patch']
            },
            {
                'apiGroups': [''],
                'resources': ['serviceaccounts',
                              'services',
                              'secrets',
                              'configmaps'],
                'verbs': ['get', 'create', 'update', 'patch']
            },
            {
                'apiGroups': ['image.openshift.io'],
                'resources': ['imagestreams'],
                'verbs': ['get', 'create', 'update', 'patch']
            }]
    })

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'config-updater',
            'namespace': context.is_namespace,
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'config-updater'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'config-updater',
            'namespace': context.config.rc_deployment_namespace,
        }]
    })

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'config-updater',
            'namespace': context.jobs_namespace,
        },
        'rules': [
            {
                'apiGroups': ['route.openshift.io'],
                'resources': ['routes'],
                'verbs': ['get', 'create', 'update', 'patch']
            },
            {
                'apiGroups': [''],
                'resources': ['services'],
                'verbs': ['get', 'create', 'update', 'patch']
            },
            {
                'apiGroups': ['image.openshift.io'],
                'resources': ['imagestreams'],
                'verbs': ['get', 'create', 'update', 'patch']
            }]
    })

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'config-updater',
            'namespace': context.jobs_namespace
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'config-updater'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'config-updater',
            'namespace': context.config.rc_deployment_namespace
        }]
    })
