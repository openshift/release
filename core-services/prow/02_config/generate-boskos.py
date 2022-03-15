#!/usr/bin/env python3

import yaml


CONFIG = {

    'aws-arm64-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'us-east-1': 10,
        'us-east-2': 8,
        'us-west-1': 8,
        'us-west-2': 8,
    },
    'aws-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'us-east-1': 50,
        'us-east-2': 35,
        'us-west-1': 35,
        'us-west-2': 35,
    },
    'aws-2-quota-slice': {
        'us-east-1': 40,
        'us-east-2': 40,
        'us-west-1': 35,
        'us-west-2': 40,
    },
    'aws-china-quota-slice': {
        'cn-north-1': 1,
        'cn-northwest-1': 1,
    },
    'aws-usgov-quota-slice': {
        'us-gov-west-1': 5,
        'us-gov-east-1': 5,
    },
    'azure4-quota-slice': {
        'centralus': 33,
        'eastus': 8,
        'eastus2': 8,
        'westus': 8
    },
    'azure-2-quota-slice': {
        'centralus': 33,
        'eastus': 8,
        'eastus2': 8,
        'westus': 8
    },
    'azurestack-quota-slice': {
        'ppe3': 2
    },
    'azuremag-quota-slice': {
        'usgovvirginia': 5
    },
    'azure-qe-quota-slice': {
        'northcentralus': 5
    },
    'azuremag-qe-quota-slice': {
        'usgovvirginia': 5
    },
    'equinix-ocp-metal-quota-slice': {
        'default': 40,
    },
    'gcp-quota-slice': {
        'us-central1': 70,
    },
    'gcp-openshift-gce-devel-ci-2-quota-slice': {
        'us-central1': 70,
    },
    'libvirt-s390x-quota-slice': {},
    'libvirt-ppc64le-quota-slice': {},
    'metal-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'default': 1000,
    },
    'openstack-osuosl-quota-slice': {},
    'openstack-quota-slice': {
        'default': 7,
    },
    'openstack-vexxhost-quota-slice': {
        'default': 18,
    },
    'openstack-kuryr-quota-slice': {
        'default': 2,
    },
    'openstack-nfv-quota-slice': {
        'default': 5,
    },
    'openstack-vh-mecha-central-quota-slice': {
        'default': 5,
    },
    'openstack-vh-mecha-az0-quota-slice': {
        'default': 5,
    },
    'openstack-ppc64le-quota-slice': {},
    'ovirt-quota-slice': {},
    'ovirt-upgrade-quota-slice': {},
    'ovirt-clusterbot-quota-slice': {
        'default': 3,
    },
    'packet-quota-slice': {
        'default': 60,
    },
    'packet-edge-quota-slice': {
        'default': 50,
    },
    'vsphere-quota-slice':{},
    'vsphere-discon-quota-slice':{},
    'vsphere-clusterbot-quota-slice':{},
    'vsphere-platform-none-quota-slice':{},
    'osd-ephemeral-quota-slice': {
        'default': 15,
    },
    'aws-cpaas-quota-slice': {
        'us-east-1': 8,
        'us-east-2': 8,
        'us-west-2': 8,
        'eu-west-1': 8,
        'eu-west-2': 8
    },
    'hypershift-quota-slice': {
        'default': 15,
    },
    'ibmcloud-quota-slice': {
        'default': 7,
    },
    'alibabacloud-quota-slice': {
        'us-east-1': 10,
    },
}

for i in range(3):
    for j in range(4):
        CONFIG['libvirt-s390x-quota-slice']['libvirt-s390x-{}-{}'.format(i, j)] = 1

for i in range(3):
    for j in range(4):
        CONFIG['libvirt-ppc64le-quota-slice']['libvirt-ppc64le-{}-{}'.format(i, j)] = 1
# Reserve one for internal debugging use
del CONFIG['libvirt-ppc64le-quota-slice']['libvirt-ppc64le-1-3']

for i in range(2):
    CONFIG['openstack-osuosl-quota-slice']['openstack-osuosl-{0:0>2}'.format(i)] = 1

for i in range(4):
    CONFIG['openstack-ppc64le-quota-slice']['openstack-ppc64le-{0:0>2}'.format(i)] = 1

for i in range(10, 24):
    CONFIG['ovirt-quota-slice']['ovirt-{}'.format(i)] = 1

for i in range(1, 7):
    CONFIG['ovirt-upgrade-quota-slice']['ovirt-upgrade-{}'.format(i)] = 1

for i in range(76,103):
    CONFIG['vsphere-quota-slice']['ci-segment-{}'.format(i)] = 1

for i in range(56,60):
    CONFIG['vsphere-platform-none-quota-slice']['ci-segment-{}'.format(i)] = 1

for i in range(60,62):
    CONFIG['vsphere-discon-quota-slice']['qe-discon-segment-{}'.format(i)] = 1

for i in range(50,54):
    CONFIG['vsphere-clusterbot-quota-slice']['ci-segment-{}'.format(i)] = 1

config = {
    'resources': [],
}

for typeName, data in sorted(CONFIG.items()):
    resource = {
        'type': typeName,
        'state': 'free',
    }
    if set(data.keys()) == {'default'}:
        resource['min-count'] = resource['max-count'] = data['default']
    else:
        resource['names'] = []
        for name, count in sorted(data.items()):
            if '--' in name:
                raise ValueError('double-dashes are used internally, so {!r} is invalid'.format(name))
            if count > 1:
                width = len(str(count-1))
                resource['names'].extend(['{name}--{typeName}-{i:0>{width}}'.format(name=name,typeName=typeName, i=i, width=width) for i in range(count)])
            else:
                resource['names'].append(name)
    config['resources'].append(resource)

with open('_boskos.yaml', 'w') as f:
    f.write('# generated with generate-boskos.py; do not edit directly\n')
    yaml.dump(config, f, default_flow_style=False)
