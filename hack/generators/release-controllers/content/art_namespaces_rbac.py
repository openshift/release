arch_in_hostname = {'arm64': 'arm64', 'ppc64le': 'ppc64le', 'multi': 'multi', 'x86_64': 'amd64', 's390x': 's390x', 'multi-2': 'multi-2'}


def get_private_release_pullers():
    """
    Users/groups that should be granted access to pull private
    nightly release payloads from ocp-priv / other namespaces.
    Users will also have access to a long-lived token capable
    of reading the images.
    """
    puller_subjects = []

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
    # It's a mapping from the "openshift-private-release-admins" Rover Group.
    puller_subjects.append({
        'apiGroup': 'rbac.authorization.k8s.io',
        'kind': 'Group',
        'name': 'openshift-private-release-admins'
    })
    # Users who are actively working in github.com/openshift-priv and need
    # access to private release controllers.
    # It's a mapping from the "openshift-private-ci-reps" Rover Group.
    puller_subjects.append({
        'apiGroup': 'rbac.authorization.k8s.io',
        'kind': 'Group',
        'name': 'openshift-private-ci-reps'
    })
    # OpenShift QE team members are permitted to pull content
    # from private CI for testing purposes.
    puller_subjects.append({
        'apiGroup': 'rbac.authorization.k8s.io',
        'kind': 'Group',
        'name': 'aos-qe'
    })
    # The ocp-priv-image-puller SA offers a token
    # that can be shared temporarily with QE /
    # private CI reps which has no permissions beyond
    # pulling private nightly payload images.
    # This makes it an ideal token for installing
    # test clusters for private nightlies since
    # otherwise, if a human user's token is used,
    # it may permit folks with kubeconfig to
    # extract and abuse the user's token.
    puller_subjects.append({
        'apiGroup': '',
        'kind': 'ServiceAccount',
        'namespace': 'ocp-priv',
        'name': 'ocp-priv-image-puller'
    })
    return puller_subjects


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
        puller_subjects.extend(get_private_release_pullers())

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
        'apiVersion': 'rbac.authorization.k8s.io/v1',
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
            'apiVersion': 'rbac.authorization.k8s.io/v1',
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
            'apiVersion': 'rbac.authorization.k8s.io/v1',
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
        'apiVersion': 'rbac.authorization.k8s.io/v1',
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
        'apiVersion': 'rbac.authorization.k8s.io/v1',
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


def add_ocp_priv_puller_token(gendoc):

    # If ART installs a cluster
    # for QE to validate a fix, that cluster will include
    # the ART user's app.ci credentials, which are
    # overly powerful. Those pull secrets could be extracted
    # from the cluster and misused. Instead, install the cluster
    # using the long lived token of this SA.
    # It will restrict use to pulling images.
    # It should be rotated periodically.
    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'ServiceAccount',
        'metadata': {
            'name': 'ocp-priv-image-puller',
            'namespace': 'ocp-priv'
        }
    }, comment='Use for QE or private CI reps as to provide a long-lived service account token.')

    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'Secret',
        'metadata': {
            'name': 'ocp-priv-image-puller-secret',
            'namespace': 'ocp-priv',
            'annotations': {
                'kubernetes.io/service-account.name': 'ocp-priv-image-puller'
            }
        },
        'type': 'kubernetes.io/service-account-token'
    }, comment='Long lived API token for ocp-priv-image-puller')

    # subjects in get_private_release_pullers()
    # will be granted this role so that they can get a
    # token capable of only reading images with no
    # further powers on app.ci
    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'ocp-priv-image-puller-token-reader',
            'namespace': 'ocp-priv',
        },
        'rules': [{
            'apiGroups': [''],
            'resources': ['secrets'],
            'verbs': ['get', 'delete'],
            'resourceNames': ['ocp-priv-image-puller-secret']
            },
            {
            'apiGroups': [''],
            'resources': ['serviceaccounts'],
            'verbs': ['get'],
            'resourceNames': ['ocp-priv-image-puller']
            }
        ]
    }, comment='A role permitting users/groups access to read the current token for ocp-priv-image-puller in ocp-priv-image-puller-secret. Secret delete permission allows users to rotate the token (app.ci will restore it on the next applyconfig).')

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'ocp-priv-image-puller-token-reader-binding',
            'namespace': 'ocp-priv'
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'ocp-priv-image-puller-token-reader'
        },
        'subjects': get_private_release_pullers(),
    })
