#!/bin/bash
set -euo pipefail

echo "Installing AWS Neuron Operator and dependencies"

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

DEVICECONFIG_SAMPLE="/tmp/deviceconfig-sample.yaml"
REPO="awslabs/operator-for-ai-chips-on-aws"
DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/deviceconfig-sample.yaml"

echo "Fetching deviceconfig-sample.yaml from latest ${REPO} release..."
if ! DOWNLOAD_STATUS=$(curl -sS -L --connect-timeout 10 --max-time 30 --retry 3 \
    --retry-connrefused --retry-delay 5 -o "${DEVICECONFIG_SAMPLE}" -w '%{http_code}' \
    "${DOWNLOAD_URL}"); then
    echo "ERROR: failed to download ${DOWNLOAD_URL}" >&2
    exit 1
fi
if [[ "${DOWNLOAD_STATUS}" != "200" || ! -s "${DEVICECONFIG_SAMPLE}" ]]; then
    echo "ERROR: deviceconfig-sample.yaml download returned HTTP ${DOWNLOAD_STATUS} or an empty file" >&2
    exit 1
fi
echo "Downloaded deviceconfig-sample.yaml"

python3 -c "
import shlex, os, sys, re

spec = {}
with open('${DEVICECONFIG_SAMPLE}') as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('#') or line.startswith('---'):
            continue
        m = re.match(r'^(\w+):\s+(.+)$', line)
        if m:
            spec[m.group(1)] = m.group(2).strip('\"')

raw_drivers_image = spec.get('driversImage', '')
force_in_cluster = os.environ.get('ECO_HWACCEL_NEURON_IN_CLUSTER_BUILD', '').lower() == 'true'
resolved_drivers_image = '' if force_in_cluster else (os.environ.get('ECO_HWACCEL_NEURON_DRIVERS_IMAGE', '') or raw_drivers_image)
in_cluster_build = not bool(resolved_drivers_image)
dra_mode = bool(os.environ.get('ECO_HWACCEL_NEURON_DRA_DRIVER_IMAGE', ''))

version_source = resolved_drivers_image or raw_drivers_image
if version_source and ':' in version_source:
    driver_version = version_source.rsplit(':', 1)[-1]
else:
    driver_version = spec.get('driverVersion', '')

mapping = {
    'ECO_HWACCEL_NEURON_DRIVERS_IMAGE': raw_drivers_image,
    'ECO_HWACCEL_NEURON_DRIVER_VERSION': driver_version,
    'ECO_HWACCEL_NEURON_DEVICE_PLUGIN_IMAGE': spec.get('devicePluginImage', ''),
    'ECO_HWACCEL_NEURON_SCHEDULER_IMAGE': spec.get('customSchedulerImage', ''),
    'ECO_HWACCEL_NEURON_SCHEDULER_EXTENSION_IMAGE': spec.get('schedulerExtensionImage', ''),
    'ECO_HWACCEL_NEURON_NODE_METRICS_IMAGE': spec.get('nodeMetricsImage', ''),
    'ECO_HWACCEL_NEURON_DRA_DRIVER_IMAGE': spec.get('draDriverImage', ''),
}

optional_when_in_cluster = {
    'ECO_HWACCEL_NEURON_DRIVERS_IMAGE',
}
dra_only = {
    'ECO_HWACCEL_NEURON_DRA_DRIVER_IMAGE',
}

image_re = re.compile(r'^[a-zA-Z0-9._/:-]+(@sha256:[0-9a-fA-F]{64})?$')

env_path = os.path.join(os.environ['SHARED_DIR'], 'neuron-deviceconfig.env')
with open(env_path, 'w') as ef:
    for key, value in mapping.items():
        if in_cluster_build and key in optional_when_in_cluster:
            ef.write(f'export {key}=\n')
            print(f'  {key}= (empty, in-cluster build mode)')
            continue
        existing = os.environ.get(key, '')
        final = existing if existing else value
        if not dra_mode and key in dra_only:
            ef.write(f'export {key}=\n')
            print(f'  {key}= (not used in this allocation mode)')
            continue
        if not final:
            print(f'ERROR: {key} resolved to empty', file=sys.stderr)
            sys.exit(1)
        if not image_re.match(final):
            print(f'ERROR: {key} contains unexpected characters: {final!r}', file=sys.stderr)
            sys.exit(1)
        ef.write(f'export {key}={shlex.quote(final)}\n')
        print(f'  {key}={final}')
    icb = 'true' if in_cluster_build else 'false'
    ef.write(f'export ECO_HWACCEL_NEURON_IN_CLUSTER_BUILD={icb}\n')
    print(f'  ECO_HWACCEL_NEURON_IN_CLUSTER_BUILD={icb}')
    mode = 'dra' if dra_mode else 'device-plugin'
    print(f'  allocation mode={mode}')
"
echo "DeviceConfig values resolved (written to SHARED_DIR/neuron-deviceconfig.env)"

source "${SHARED_DIR}/neuron-deviceconfig.env"

make cluster-operators
