#!/usr/bin/env python3

import yaml


CONFIG = {
    'aws-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'us-east-1': 50,
        'us-east-2': 35,
        'us-west-1': 35,
        'us-west-2': 35,
    },
    'azure4-quota-slice': {
        'centralus': 33,
        'eastus': 10,
        'eastus2': 10,
        'westus': 10
    },
    'gcp-quota-slice': {
        'us-east1': 80,
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
        'default': 3,
    },
    'openstack-ppc64le-quota-slice': {},
    'ovirt-quota-slice': {},
    'packet-quota-slice': {
        'default': 30,
    },
    'kubevirt-quota-slice':{},
    'vsphere-quota-slice':{},
    'osd-ephemeral-quota-slice': {
        'default': 5,
    },
    'aws-cpaas-quota-slice': {
        'us-east-1': 8,
        'us-east-2': 8,
        'us-west-2': 8
    }
}

for i in range(2):
    for j in range(5):
        CONFIG['libvirt-s390x-quota-slice']['libvirt-s390x-{}-{}'.format(i, j)] = 1

for i in range(2):
    for j in range(4):
        CONFIG['libvirt-ppc64le-quota-slice']['libvirt-ppc64le-{}-{}'.format(i, j)] = 1

for i in range(1, 5):
    CONFIG['openstack-osuosl-quota-slice']['openstack-osuosl-{0:0>2}'.format(i)] = 1

for i in range(4):
    CONFIG['openstack-ppc64le-quota-slice']['openstack-ppc64le-{0:0>2}'.format(i)] = 1

for i in range(10, 20):
    CONFIG['ovirt-quota-slice']['ovirt-{}'.format(i)] = 1

for i in range(1, 3):
    CONFIG['kubevirt-quota-slice']['tenant-cluster-{}'.format(i)] = 1

for i in range(0,10):
    CONFIG['vsphere-quota-slice']['ci-segment-{}'.format(i)] = 1

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
                resource['names'].extend(['{name}--{i:0>{width}}'.format(name=name, i=i, width=width) for i in range(count)])
            else:
                resource['names'].append(name)
    config['resources'].append(resource)

with open('_boskos.yaml', 'w') as f:
    f.write('# generated with generate-boskos.py; do not edit directly\n')
    yaml.dump(config, f, default_flow_style=False)
