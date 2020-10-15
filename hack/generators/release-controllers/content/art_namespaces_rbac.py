

def add_imagestream_namespace_rbac(gendoc):
    resources = gendoc
    context = gendoc.context

    puller_subjects = []
    if not context.private:
        puller_subjects.append({
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'system:authenticated'
        })
    else:
        puller_subjects.append({
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'openshift-priv-admins'
        })
        puller_subjects.append({
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'qe'
        })
        puller_subjects.append({
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'release-team'
        })

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1beta1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'image-puller',
            'namespace': context.is_namespace
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'ClusterRole',
            'name': 'system:image-puller'
        },
        'subjects': puller_subjects,
    })

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1beta1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'user-viewer',
            'namespace': context.is_namespace
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'ClusterRole',
            'name': 'view'
        },
        'subjects': puller_subjects,
    })

    resources.append({
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': f'release-controller-modify',
            'namespace': context.is_namespace
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
                'apiGroups': [''],
                'resources': ['events'],
                'verbs': ['create', 'patch', 'update']
            }]
    })

    if not context.suffix:
        # Special permissions for x86_64 public rc
        resources.append({
            'apiVersion': 'authorization.openshift.io/v1',
            'kind': 'Role',
            'metadata': {
                'name': 'release-controller-modify-ocp',
                'namespace': 'openshift'
            },
            'rules': [{
                'apiGroups': ['image.openshift.io'],
                'resourceNames': ['origin-v4.0'],
                'resources': ['imagestreams'],
                'verbs': ['get', 'list', 'watch', 'update', 'patch']
            }]
        })

        resources.append({
            'apiVersion': 'authorization.openshift.io/v1',
            'kind': 'Role',
            'metadata': {
                'name': 'release-controller-modify-ocp',
                'namespace': 'origin'
            },
            'rules': [{
                'apiGroups': ['image.openshift.io'],
                'resourceNames': ['release',
                                  *context.config.releases,
                                  ],
                'resources': ['imagestreams'],
                'verbs': ['get', 'list', 'watch', 'update', 'patch']
            }]
        })

    resources.append({
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': f'release-controller-import-ocp',
            'namespace': context.is_namespace
        },
        'rules': [{
            'apiGroups': ['image.openshift.io'],
            'resources': ['imagestreamimports'],
            'verbs': ['create']
        }]
    })

    resources.append({
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': f'release-controller{context.suffix}-prowjob',
            'namespace': context.config.rc_deployment_namespace,
        },
        'rules': [{
            'apiGroups': ['prow.k8s.io'],
            'resources': ['prowjobs'],
            'verbs': ['get',
                      'list',
                      'watch',
                      'create',
                      'delete',
                      'update',
                      'patch']
        }]
    })

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'release-controller-binding-ocp',
            'namespace': context.is_namespace,
        },
        'roleRef': {
            'kind': 'Role',
            'name': f'release-controller-modify'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': context.rc_serviceaccount_name,
            'namespace': context.config.rc_deployment_namespace
        }]
    })

    if not context.suffix:
        # Special permissions just for x86_64 public release controller
        resources.append({
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'RoleBinding',
            'metadata': {
                'name': 'release-controller-binding-ocp',
                'namespace': 'openshift'
            },
            'roleRef': {
                'kind': 'Role',
                'name': 'release-controller-modify-ocp'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-controller-ocp',
                'namespace': context.config.rc_deployment_namespace
            }]
        })

        resources.append({
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'RoleBinding',
            'metadata': {
                'name': 'release-controller-binding-ocp',
                'namespace': 'origin'
            },
            'roleRef': {
                'kind': 'Role',
                'name': 'release-controller-modify-ocp'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'release-controller-ocp',
                'namespace': context.config.rc_deployment_namespace,
            }]
        })

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'release-controller-binding-view',
            'namespace': context.is_namespace
        },
        'roleRef': {
            'kind': 'ClusterRole',
            'name': 'view'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': context.rc_serviceaccount_name,
            'namespace': context.config.rc_deployment_namespace
        }]
    })

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': f'release-controller-binding-prowjob-{context.is_namespace}',
            'namespace': context.config.rc_deployment_namespace
        },
        'roleRef': {
            'kind': 'Role',
            'name': f'release-controller{context.suffix}-prowjob'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': context.rc_serviceaccount_name,
            'namespace': context.config.rc_deployment_namespace
        }]
    })

    resources.append({
        'apiVersion': 'v1',
        'kind': 'Namespace',
        'metadata': {
            'name': context.jobs_namespace,
        }
    })

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': f'release-controller-binding-ocp',
            'namespace': context.jobs_namespace,
        },
        'roleRef': {
            'kind': 'ClusterRole',
            'name': 'edit'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': context.rc_serviceaccount_name,
            'namespace': context.config.rc_deployment_namespace
        }]
    })

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'release-controller-binding-promote',
            'namespace': context.is_namespace,
        },
        'roleRef': {
            'kind': 'ClusterRole',
            'name': 'system:image-builder'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'builder',
            'namespace': context.jobs_namespace,
        }]
    })

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'release-controller-binding-import',
            'namespace': context.is_namespace,
        },
        'roleRef': {
            'kind': 'Role',
            'name': f'release-controller-import-ocp',
            'namespace': context.is_namespace,
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'builder',
            'namespace': context.jobs_namespace,
        }]
    })

    resources.append({
        'apiVersion': 'v1',
        'kind': 'Secret',
        'metadata': {
            'name': 'release-upgrade-graph',
            'namespace': context.is_namespace
        }
    })

    resources.append({
        'apiVersion': 'v1',
        'kind': 'ServiceAccount',
        'metadata': {
            'annotations': {} if not context.private else {
                f'serviceaccounts.openshift.io/oauth-redirectreference.{context.rc_serviceaccount_name}': '{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"%s"}}' % context.rc_route_name
            },
            'name': context.rc_serviceaccount_name,
            'namespace': context.config.rc_deployment_namespace,
        }
    })
