#!/bin/bash

set -o nounset

mkdir -p /tmp/bin
export PATH="/cli:/tmp/bin:${PATH}"

echo "$(date -u --rfc-3339=seconds) - Installing tools..."

# install jq
# TODO move to image
curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/bin/jq
chmod ug+x /tmp/bin/jq

if ! command -v /cli/oc >/dev/null 2>&1; then
  echo "ERROR: oc not found (expected /cli/oc from cli: latest). Cannot continue."
  exit 1
fi

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(cat ${AZURE_AUTH_LOCATION} | jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(cat ${AZURE_AUTH_LOCATION} | jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(cat ${AZURE_AUTH_LOCATION} | jq -r .tenantId)"

CLUSTER_NAME="$(oc get -o jsonpath='{.status.infrastructureName}' infrastructure cluster)"
echo "Cluster name: $CLUSTER_NAME"
CLUSTER_VERSION="$(oc adm release info -o json | jq -r .metadata.version)"
echo "Cluster version: $CLUSTER_VERSION"
RESOURCE_GROUP="$(oc get -o jsonpath='{.status.platformStatus.azure.resourceGroupName}' infrastructure cluster)"
echo "Resource group: $RESOURCE_GROUP"
SUBSCRIPTION_ID="$(oc get configmap -n openshift-config cloud-provider-config -o jsonpath='{.data.config}' | jq -r '.subscriptionId')"
echo "Subscription ID: $SUBSCRIPTION_ID"

echo "$(date -u --rfc-3339=seconds) - Logging in to Azure..."
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}"

echo "$(date -u --rfc-3339=seconds) - Listing load balancer resources"
LB_RESOURCES="$(az resource list --resource-type Microsoft.Network/loadBalancers --resource-group $RESOURCE_GROUP --subscription $SUBSCRIPTION_ID | jq -r '.[].id')"

OUTPUT_DIR="${ARTIFACT_DIR}/azure-monitor-metrics/"
mkdir -p "$OUTPUT_DIR"

for i in $LB_RESOURCES; do
    echo "$i"
    LB_NAME="$(basename $i)" # Grabs the last token of the resource id, which is it's friendly name.
    echo "$LB_NAME"
    metrics=( SnatConnectionCount AllocatedSnatPorts UsedSnatPorts PacketCount ByteCount )
    for m in "${metrics[@]}";
    do
        echo "$(date -u --rfc-3339=seconds) - Gathering metric $m for load balancer $i"
        az monitor metrics list --resource $i --offset 3h --metrics $m --subscription $SUBSCRIPTION_ID > $OUTPUT_DIR/lb-$LB_NAME-$m.json
    done
    # One-off additional filter for failed connections:
    az monitor metrics list --resource $i --offset 3h --metrics SnatConnectionCount --filter "ConnectionState eq 'Failed'"  --subscription $SUBSCRIPTION_ID > $OUTPUT_DIR/lb-$LB_NAME-SnatConnectionCount-ConnectionFailed.json
done

echo "$(date -u --rfc-3339=seconds) - Gathering load balancer resources complete"

# Gather Azure console logs.
echo "$(date -u --rfc-3339=seconds) - Gathering console logs"

if test -f "${KUBECONFIG}"
then
  TMPDIR=/tmp/azure-boot-logs
  mkdir -p $TMPDIR
  oc --request-timeout=5s -n openshift-machine-api get machines -o jsonpath --template '{range .items[*]}{.metadata.name}{"\n"}{end}' >> "${TMPDIR}/azure-instance-names.txt"
  RESOURCE_GROUP="$(oc get -o jsonpath='{.status.platformStatus.azure.resourceGroupName}' infrastructure cluster)"
else
  echo "No kubeconfig; skipping boot log extraction."
  exit 0
fi

az version

EXIT_CODE=0
# This allows us to continue and try to gather other boot logs.
set +o errexit
set -o pipefail

echo "$(date -u --rfc-3339=seconds) - Gathering disk metrics"
for VM_NAME in $(sort < "${TMPDIR}/azure-instance-names.txt" | uniq)
do
  metrics=( "OS Disk Queue Depth" "OS Disk Write Bytes/Sec" )
  for m in "${metrics[@]}";
  do
    echo "$(date -u --rfc-3339=seconds) - Gathering metric $m for VM ${VM_NAME}"
    az monitor metrics list --resource-type "Microsoft.Compute/virtualMachines" --resource ${VM_NAME} --resource-group "${RESOURCE_GROUP}" --offset 3h --metrics "$m" --subscription $SUBSCRIPTION_ID > $OUTPUT_DIR/disk-$VM_NAME-${m//[^[:alnum:]]/""}.json
  done
done
echo "$(date -u --rfc-3339=seconds) - Gathering disk metrics complete"

# Boot diagnostics output is a raw framebuffer/serial capture with ANSI cursor/color
# codes and Unicode box-drawing. Strip escapes and map common box chars to ASCII so
# artifacts are readable in Prow/GCS without a terminal emulator.
sanitize_boot_log() {
  local boot_log="$1"
  [[ -f "${boot_log}" ]] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    echo "WARNING: python3 not found; skipping ANSI/box-drawing cleanup for ${boot_log}"
    return 0
  fi
  python3 - "${boot_log}" <<'PY'
import ast
import re
import sys

path = sys.argv[1]
with open(path, "rb") as f:
    raw = f.read()


def unwrap_bytes_repr(data: bytes) -> bytes:
    """Azure CLI may emit the boot log as a Python bytes literal (ASCII), e.g. b'\\x1b[2J...'
    instead of raw binary. In that form ESC is the four characters \\x1b, so ANSI stripping
    must happen after decoding the literal to real bytes."""
    s = data.lstrip()
    if not (s.startswith(b"b'") or s.startswith(b'b"')):
        return data
    try:
        text = data.decode("ascii")
        obj = ast.literal_eval(text.strip())
        if isinstance(obj, (bytes, bytearray)):
            return bytes(obj)
    except (SyntaxError, ValueError, UnicodeDecodeError):
        pass
    return data


data = unwrap_bytes_repr(raw)

# CSI/OSC-style ANSI escapes (binary-safe)
## Note: this is a binary-safe regex that matches ANSI escape sequences.
ansi = re.compile(br"\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])")
# Remove ANSI escape sequences
data = ansi.sub(b"", data)
# Normalize line endings to Unix-style LF (binary-safe)
data = data.replace(b"\r\n", b"\n").replace(b"\r", b"\n")

text = data.decode("utf-8", errors="replace")
# Light-duty box drawing + common GRUB arrow glyphs -> ASCII
box = str.maketrans(
    {
        "┌": "+",
        "┐": "+",
        "└": "+",
        "┘": "+",
        "─": "-",
        "│": "|",
        "├": "+",
        "┤": "+",
        "┬": "+",
        "┴": "+",
        "┼": "+",
        "▲": "^",
        "▼": "v",
    }
)
text = text.translate(box)

with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(text)
PY
}

for VM_NAME in $(sort < "${TMPDIR}/azure-instance-names.txt" | uniq)
do
  echo "Gathering console logs for ${VM_NAME} in resource group ${RESOURCE_GROUP}"
  # Write directly to the artifact file (avoid `echo $(az ...)` as it was producing
  # errors as: "UnicodeDecodeError: 'utf-8' codec can't decode byte 0xe2 in position 348729: invalid continuation byte"
  BOOT_LOG_TMP="${ARTIFACT_DIR}/${VM_NAME}-boot.log.tmp"
  if ! az vm boot-diagnostics get-boot-log \
    --name "${VM_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --subscription "${SUBSCRIPTION_ID}" \
    -o tsv \
    >"${BOOT_LOG_TMP}" 2>&1
  then
    EXIT_CODE="${?}"
  fi
  sanitize_boot_log "${BOOT_LOG_TMP}"
  mv -f "${BOOT_LOG_TMP}" "${ARTIFACT_DIR}/${VM_NAME}-boot.log"
done

echo "$(date -u --rfc-3339=seconds) - Gathering console logs complete"

exit "${EXIT_CODE}"
