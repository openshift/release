#!/usr/bin/env python3

import yaml


CONFIG = {
    'aws-quota-slice': {
        'default': 150,
    },
    'azure4-quota-slice': {
        'default': 30,
    },
    'gcp-quota-slice': {
        'default': 120,
    },
    'libvirt-s390x-quota-slice': {},
    'libvirt-ppc64le-quota-slice': {},
    'metal-quota-slice': {
        # Wild guesses.  We'll see when we hit quota issues
        'default': 1000,
    },
    'openstack-OSUOSL-quota-slice': {},
    'openstack-quota-slice': {
        'default': 7,
    },
    'openstack-vexxhost-quota-slice': {
        'default': 3,
    },
    'openstack-ppc64le-quota-slice': {},
    'ovirt-quota-slice': {},
    'packet-quota-slice': {
        'default': 20,
    },
    'vsphere-quota-slice': {
        'default': 10,
    },
}

for i in range(1):
    for j in range(5):
        CONFIG['libvirt-s390x-quota-slice']['libvirt-s390x-{}-{}'.format(i, j)] = 1

for i in range(2):
    for j in range(4):
        CONFIG['libvirt-ppc64le-quota-slice']['libvirt-ppc64le-{}-{}'.format(i, j)] = 1

for i in range(1, 5):
    CONFIG['openstack-OSUOSL-quota-slice']['openstack-OSUOSL-{0:0>2}'.format(i)] = 1

for i in range(4):
    CONFIG['openstack-ppc64le-quota-slice']['openstack-ppc64le-{0:0>2}'.format(i)] = 1

for i in range(10, 18):
    CONFIG['ovirt-quota-slice']['ovirt-{}'.format(i)] = 1

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
            resource['names'].extend([name]*count)
    config['resources'].append(resource)

with open('_boskos.yaml', 'w') as f:
    f.write('# generated with generate-boskos.py; do not edit directly\n')
    yaml.dump(config, f, default_flow_style=False)
