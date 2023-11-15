arch_in_hostname = {'arm64': 'arm64', 'ppc64le': 'ppc64le', 'multi': 'multi', 'x86_64':'amd64', 's390x':'s390x'}

def add_imagestream_namespace_rbac(gendoc):
    resources = gendoc
    context = gendoc.context
    hostname_prefix = arch_in_hostname[context.arch]

    puller_subjects = []
    if not context.private:
        puller_subjects.append({
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'system:authenticated'
        })
    else:
        # This group contains cluster admins on OpenShift CI build farm clusters
        puller_subjects.append({
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'test-platform-ci-admins'
        })
        # This group contains members of the OpenShift release team (ART) with some extra capabilities
        puller_subjects.append({
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'art-admins'
        })
        # This group contains users with the ability to access the private release-controllers
        # It's a mapping from the "openshift-private-release-admins" Rover Group
        puller_subjects.append({
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Group',
            'name': 'openshift-private-release-admins'
        })

    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
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
        'apiVersion': 'rbac.authorization.k8s.io/v1',
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
            'name': 'release-controller-modify',
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
            'rules': [
                {
                    'apiGroups': ['image.openshift.io'],
                    'resourceNames': ['release',
                                      *context.config.releases,
                                      *context.config.scos_releases],
                    'resources': ['imagestreams'],
                    'verbs': ['get', 'list', 'watch', 'update', 'patch']
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
                }
            ]
        })

    resources.append({
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'release-controller-import-ocp',
            'namespace': context.is_namespace
        },
        'rules': [{
            'apiGroups': ['image.openshift.io'],
            'resources': ['imagestreamimports'],
            'verbs': ['create']
        }, {
            'apiGroups': ['image.openshift.io'],
            'resources': ['imagestreams'],
            'verbs': ['get', 'list']
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
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'release-controller-modify'
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
                'apiGroup': 'rbac.authorization.k8s.io',
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
                'apiGroup': 'rbac.authorization.k8s.io',
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
            'apiGroup': 'rbac.authorization.k8s.io',
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
            'apiGroup': 'rbac.authorization.k8s.io',
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
            'name': 'release-controller-binding-ocp',
            'namespace': context.jobs_namespace,
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
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
            'apiGroup': 'rbac.authorization.k8s.io',
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
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'release-controller-import-ocp',
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
                f'serviceaccounts.openshift.io/oauth-redirectreference.{context.rc_serviceaccount_name}': f'{{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{{"kind":"Route","name":"{context.rc_route_name}"}}}}',
                f'serviceaccounts.openshift.io/oauth-redirecturi.{context.rc_serviceaccount_name}-ingress': f'https://{hostname_prefix}.ocp.internal.releases.ci.openshift.org'
            },
            'name': context.rc_serviceaccount_name,
            'namespace': context.config.rc_deployment_namespace,
        }
    })

    if context.private:
        resources.append({
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRoleBinding',
            'metadata': {
                'name': f'release-controller-ocp{context.suffix}-oauth'
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'ClusterRole',
                'name': 'release-controller-priv-oauth'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': context.rc_serviceaccount_name,
                'namespace': context.config.rc_deployment_namespace
            }]
        })

    resources.append(
        {
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRoleBinding',
            'metadata': {
                'name': f'release-controller-ocp{context.suffix}',
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'ClusterRole',
                'name': 'release-controller'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': context.rc_serviceaccount_name,
                'namespace': context.config.rc_deployment_namespace
            }]
        }
    )
