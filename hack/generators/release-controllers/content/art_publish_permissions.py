

def add_art_publish(gendoc):
    config = gendoc.context

    gendoc.append({
        'apiVersion': 'v1',
        'kind': 'ServiceAccount',
        'metadata': {
            'name': 'art-publish',
            'namespace': 'ocp'
        }
    })

    gendoc.append_all([{
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'art-manage-art-equivalent-buildconfigs',
            'namespace': 'ci'
        },
        'rules': [{
            'apiGroups': ['build.openshift.io', 'apps', 'extensions'],
            'resources': ['buildconfigs', 'buildconfigs/instantiate', 'builds', 'daemonsets'],
            'verbs': ['create', 'get', 'list', 'watch', 'update', 'patch']
        }]
    }, {
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'art-manage-art-equivalent-buildconfigs',
            'namespace': 'ci'
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'art-manage-art-equivalent-buildconfigs'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'art-publish',
            'namespace': 'ocp'
        }]
    }], comment='''Allow ART to create buildconfigs to manifest ART equivalent images for upstream CI.
Also permit the creation of daemonsets to ensure kubelet does not gc builder images from nodes (bug
in 3.11).''')

    gendoc.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'art-publish',
            'namespace': 'openshift'
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'ClusterRole',
            'name': 'system:image-builder'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'art-publish',
            'namespace': 'ocp'
        }]
    }, comment='Allow ART to mirror images to the openshift namespace so ci-build-root "release" images can be pushed')

    gendoc.append_all([{
        'apiVersion': 'authorization.openshift.io/v1',
        'kind': 'Role',
        'metadata': {
            'name': 'art-prowjob',
            'namespace': 'ci'
        },
        'rules': [{
            'apiGroups': ['prow.k8s.io'],
            'resources': ['prowjobs'],
            'verbs': ['create', 'get', 'list', 'watch', 'update', 'patch']
        }]
    }, {
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': 'art-create-prowjobs',
            'namespace': 'ci'
        },
        'roleRef': {
            'apiGroup': 'rbac.authorization.k8s.io',
            'kind': 'Role',
            'name': 'art-prowjob'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'art-publish',
            'namespace': 'ocp'
        }]
    }], comment='Allow ART to create prowjobs in the ci namespace for running upgrade tests')

    for private in (False, True):
        for arch in config.arches:

            gendoc.append({
                'apiVersion': 'v1',
                'kind': 'Namespace',
                'metadata': {
                    'name': f'ocp{config.get_suffix(arch, private)}'
                }
            })

            for major_minor in config.releases:
                gendoc.append({
                    'apiVersion': 'v1',
                    'kind': 'ImageStream',
                    'metadata': {
                        'name': major_minor,
                        'namespace': f'ocp{config.get_suffix(arch, private)}'
                    }
                })
                gendoc.append({
                    'apiVersion': 'v1',
                    'kind': 'ImageStream',
                    'metadata': {
                        'name': f'{major_minor}-art-latest{config.get_suffix(arch, private)}',
                        'namespace': f'ocp{config.get_suffix(arch, private)}'
                    }
                })

            gendoc.append({
                'apiVersion': 'authorization.openshift.io/v1',
                'kind': 'Role',
                'metadata': {
                    'name': 'art-publish-modify-release',
                    'namespace': f'ocp{config.get_suffix(arch, private)}'
                },
                'rules': [
                    {
                        'apiGroups': ['image.openshift.io'],
                        'resources': ['imagestreams'],
                        'verbs': ['get', 'list', 'watch', 'update', 'patch']
                    },
                    {
                        'apiGroups': ['image.openshift.io'],
                        'resources': ['imagestreamtags'],
                        'verbs': ['get', 'list', 'watch', 'update', 'patch', 'delete']
                    }
                ]
            })

            gendoc.append({
                'apiVersion': 'authorization.openshift.io/v1',
                'kind': 'Role',
                'metadata': {
                    'name': 'art-backup-upgrade-graph',
                    'namespace': f'ocp{config.get_suffix(arch, private)}'
                },
                'rules': [{
                    'apiGroups': [''],
                    'resourceNames': ['release-upgrade-graph'],
                    'resources': ['secrets'],
                    'verbs': ['get']
                }]
            })

            gendoc.append({
                'apiVersion': 'rbac.authorization.k8s.io/v1',
                'kind': 'RoleBinding',
                'metadata': {
                    'name': 'art-publish-modify-release',
                    'namespace': f'ocp{config.get_suffix(arch, private)}'
                },
                'roleRef': {
                    'apiGroup': 'rbac.authorization.k8s.io',
                    'kind': 'Role',
                    'name': 'art-publish-modify-release'
                },
                'subjects': [{
                    'kind': 'ServiceAccount',
                    'name': 'art-publish',
                    'namespace': 'ocp'
                }]
            })

            gendoc.append({
                'apiVersion': 'rbac.authorization.k8s.io/v1',
                'kind': 'RoleBinding',
                'metadata': {
                    'name': 'art-backup-upgrade-graph',
                    'namespace': f'ocp{config.get_suffix(arch, private)}'
                },
                'roleRef': {
                    'apiGroup': 'rbac.authorization.k8s.io',
                    'kind': 'Role',
                    'name': 'art-backup-upgrade-graph'
                },
                'subjects': [{
                    'kind': 'ServiceAccount',
                    'name': 'art-publish',
                    'namespace': 'ocp'
                }]
            })

            gendoc.append({
                'apiVersion': 'rbac.authorization.k8s.io/v1',
                'kind': 'RoleBinding',
                'metadata': {
                    'name': 'art-publish',
                    'namespace': f'ocp{config.get_suffix(arch, private)}'
                },
                'roleRef': {
                    'apiGroup': 'rbac.authorization.k8s.io',
                    'kind': 'ClusterRole',
                    'name': 'system:image-builder'
                },
                'subjects': [{
                    'kind': 'ServiceAccount',
                    'name': 'art-publish',
                    'namespace': 'ocp'
                }]
            })
