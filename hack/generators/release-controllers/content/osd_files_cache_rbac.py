def add_osd_files_cache_service_account_resources(gendoc):
    resources = gendoc
    context = gendoc.context

    if context.private:
        # If private, we need an oauth proxy in front of the files-cache
        resources.append({
            'apiVersion': 'v1',
            'kind': 'ServiceAccount',
            'metadata': {
                'annotations': {
                    'serviceaccounts.openshift.io/oauth-redirectreference.files-cache-oauth-proxy': '{"kind":"OAuthRedirectReference","apiVersion":"v1","reference":{"kind":"Route","name":"files-cache-oauth-proxy"}}'
                },
                'name': 'files-cache-oauth',
                'namespace': context.jobs_namespace,
            }
        })

        resources.append({
            'apiVersion': 'rbac.authorization.k8s.io/v1',
            'kind': 'ClusterRoleBinding',
            'metadata': {
                'name': f'files-cache-oauth{context.suffix}'
            },
            'roleRef': {
                'apiGroup': 'rbac.authorization.k8s.io',
                'kind': 'ClusterRole',
                'name': 'files-cache-oauth-priv'
            },
            'subjects': [{
                'kind': 'ServiceAccount',
                'name': 'files-cache-oauth',
                'namespace': context.jobs_namespace
            }]
        })

    # The release-controller's caches, running as the 'default' user, need explicit
    # access to `oc adm release` commands in the jobs_namespace.
    resources.append({
        'apiVersion': 'rbac.authorization.k8s.io/v1',
        'kind': 'RoleBinding',
        'metadata': {
            'name': f'release-controller-jobs-binding',
            'namespace': context.is_namespace,
        },
        'roleRef': {
            'kind': 'ClusterRole',
            'name': 'edit'
        },
        'subjects': [{
            'kind': 'ServiceAccount',
            'name': 'default',
            'namespace': context.jobs_namespace
        }]
    })
