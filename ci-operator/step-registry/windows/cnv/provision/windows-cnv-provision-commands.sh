#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "=== Windows CNV Provision: Creating KubeVirt Windows VM(s) for WMCO BYOH ==="

CNV_WINDOWS_VERSION="${CNV_WINDOWS_VERSION:-2025}"
CNV_WINDOWS_VM_COUNT="${CNV_WINDOWS_VM_COUNT:-1}"
CNV_WINDOWS_BOOT_SOURCE_URL="${CNV_WINDOWS_BOOT_SOURCE_URL:-}"
VM_NAMESPACE="default"

if [[ "${CNV_WINDOWS_VM_COUNT}" -gt 1 ]]; then
  echo "ERROR: CNV_WINDOWS_VM_COUNT=${CNV_WINDOWS_VM_COUNT} exceeds maximum of 1 (golden image import ~60m + per-VM ~70m; step timeout is 2h30m)"
  exit 1
fi
OS_IMAGES_NAMESPACE="openshift-virtualization-os-images"

case "${CNV_WINDOWS_VERSION}" in
  2025)
    DV_NAME="win2k25-ci"
    PREFERENCE_NAME="windows.2k25.virtio"
    CNV_WINDOWS_BOOT_SOURCE_URL="${CNV_WINDOWS_BOOT_SOURCE_URL:-docker://quay.io/openshift-cnv/containerdisks:windows2k25}"
    ;;
  2022)
    DV_NAME="win2k22-ci"
    PREFERENCE_NAME="windows.2k22.virtio"
    CNV_WINDOWS_BOOT_SOURCE_URL="${CNV_WINDOWS_BOOT_SOURCE_URL:-docker://quay.io/openshift-cnv/containerdisks:windows2k22}"
    ;;
  *)
    echo "ERROR: Unsupported Windows version: ${CNV_WINDOWS_VERSION}"
    exit 1
    ;;
esac

# Read SSH public key from cluster profile
if [[ ! -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
  echo "ERROR: ${CLUSTER_PROFILE_DIR}/ssh-publickey not found"
  exit 1
fi
SSH_PUBLIC_KEY=$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")
echo "SSH public key loaded from cluster profile"

# --- Step 1: Import golden image DataVolume ---
echo "$(date -u --rfc-3339=seconds) - Importing golden image from ${CNV_WINDOWS_BOOT_SOURCE_URL}..."

if ! oc get namespace "${OS_IMAGES_NAMESPACE}" 2>/dev/null; then
  echo "ERROR: Namespace ${OS_IMAGES_NAMESPACE} does not exist. OpenShift Virtualization may not be installed correctly."
  exit 1
fi

# Registry auth Secret for quay.io/openshift-cnv/containerdisks
# Credentials are mounted from test-credentials/openshift-cnv-containerdisks-auth
# at /tmp/cnv-registry-auth by the CI credentials mechanism (see ref YAML).
REGISTRY_AUTH_SECRET="openshift-cnv-containerdisks-auth"
CNV_REGISTRY_AUTH_DIR="/tmp/cnv-registry-auth"

if [[ ! -d "${CNV_REGISTRY_AUTH_DIR}" ]]; then
  echo "ERROR: Registry auth credentials not found at ${CNV_REGISTRY_AUTH_DIR}"
  echo "Ensure the openshift-cnv-containerdisks-auth secret exists in the test-credentials namespace"
  exit 1
fi

if ! oc get secret "${REGISTRY_AUTH_SECRET}" -n "${OS_IMAGES_NAMESPACE}" 2>/dev/null; then
  # Only copy the credential keys, not the secretsync metadata files
  oc create secret generic "${REGISTRY_AUTH_SECRET}" \
    -n "${OS_IMAGES_NAMESPACE}" \
    --from-file=accessKeyId="${CNV_REGISTRY_AUTH_DIR}/accessKeyId" \
    --from-file=secretKey="${CNV_REGISTRY_AUTH_DIR}/secretKey"
  echo "$(date -u --rfc-3339=seconds) - Created registry auth Secret ${REGISTRY_AUTH_SECRET} from mounted credentials"
  echo "$(date -u --rfc-3339=seconds) - Secret keys: $(oc get secret "${REGISTRY_AUTH_SECRET}" -n "${OS_IMAGES_NAMESPACE}" -o jsonpath='{.data}' | jq -r 'keys | join(", ")')"
fi

echo "$(date -u --rfc-3339=seconds) - Checking default StorageClass..."
oc get sc -o name 2>/dev/null || true

cat <<EOF | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${DV_NAME}
  namespace: ${OS_IMAGES_NAMESPACE}
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: 'true'
spec:
  source:
    registry:
      url: '${CNV_WINDOWS_BOOT_SOURCE_URL}'
      secretRef: ${REGISTRY_AUTH_SECRET}
  storage:
    accessModes:
      - ReadWriteOnce
    volumeMode: Filesystem
    resources:
      requests:
        storage: 64Gi
EOF

echo "$(date -u --rfc-3339=seconds) - DataVolume created. Checking PVC status..."
sleep 10
oc get pvc -n "${OS_IMAGES_NAMESPACE}" 2>/dev/null || true
oc get pods -n "${OS_IMAGES_NAMESPACE}" 2>/dev/null || true

echo "$(date -u --rfc-3339=seconds) - Waiting for DataVolume import to complete (this may take 20-40 minutes)..."
echo "$(date -u --rfc-3339=seconds) - Monitoring DataVolume progress..."

dv_timeout=3600
dv_interval=30
dv_elapsed=0
dv_succeeded=false
while [[ ${dv_elapsed} -lt ${dv_timeout} ]]; do
  dv_phase=$(oc get datavolume "${DV_NAME}" -n "${OS_IMAGES_NAMESPACE}" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
  dv_progress=$(oc get datavolume "${DV_NAME}" -n "${OS_IMAGES_NAMESPACE}" \
    -o jsonpath='{.status.progress}' 2>/dev/null || echo "N/A")

  if [[ "${dv_phase}" == "Succeeded" ]]; then
    dv_succeeded=true
    break
  elif [[ "${dv_phase}" == "Failed" ]]; then
    echo "ERROR: DataVolume import failed"
    oc get datavolume "${DV_NAME}" -n "${OS_IMAGES_NAMESPACE}" -o yaml
    echo "--- CDI importer pod logs ---"
    oc logs -n "${OS_IMAGES_NAMESPACE}" -l "cdi.kubevirt.io/storage.import.importPvcName=${DV_NAME}" --tail=50 2>/dev/null || true
    exit 1
  fi

  # Show importer pod and PVC status if stuck in ImportScheduled (every 2 min after 1 min)
  if [[ "${dv_phase}" == "ImportScheduled" && ${dv_elapsed} -ge 60 && $(( dv_elapsed % 120 )) -eq 0 ]]; then
    echo "--- Diagnostic: stuck at ImportScheduled (${dv_elapsed}s) ---"
    echo "PVC status:"
    oc get pvc -n "${OS_IMAGES_NAMESPACE}" 2>/dev/null || true
    echo "Importer pods:"
    oc get pods -n "${OS_IMAGES_NAMESPACE}" -o wide 2>/dev/null || true
    echo "DataVolume conditions:"
    oc get datavolume "${DV_NAME}" -n "${OS_IMAGES_NAMESPACE}" -o jsonpath='{.status.conditions}' 2>/dev/null | python3 -m json.tool 2>/dev/null || true
    echo "Recent events:"
    oc get events -n "${OS_IMAGES_NAMESPACE}" --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true
    echo "--- end diagnostic ---"
  fi

  echo "$(date -u --rfc-3339=seconds) - DataVolume phase: ${dv_phase}, progress: ${dv_progress} (${dv_elapsed}s/${dv_timeout}s)"
  sleep ${dv_interval}
  dv_elapsed=$((dv_elapsed + dv_interval))
done

if [[ "${dv_succeeded}" != "true" ]]; then
  echo "ERROR: DataVolume import timed out after ${dv_timeout}s"
  oc get datavolume "${DV_NAME}" -n "${OS_IMAGES_NAMESPACE}" -o yaml
  echo "--- CDI importer pod logs ---"
  oc logs -n "${OS_IMAGES_NAMESPACE}" -l "cdi.kubevirt.io/storage.import.importPvcName=${DV_NAME}" --tail=100 2>/dev/null || true
  echo "--- Events in ${OS_IMAGES_NAMESPACE} ---"
  oc get events -n "${OS_IMAGES_NAMESPACE}" --sort-by='.lastTimestamp' | tail -20 || true
  exit 1
fi

echo "$(date -u --rfc-3339=seconds) - Golden image import complete"

# --- Step 2: Create headless Service ---
echo "$(date -u --rfc-3339=seconds) - Creating headless Service for pod IP DNS resolution..."

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Service
metadata:
  name: headless
  namespace: ${VM_NAMESPACE}
spec:
  clusterIP: None
  selector:
    network.kubevirt.io/headlessService: headless
EOF

# --- Step 3: Provision VMs ---
vm_index=0
while [[ ${vm_index} -lt ${CNV_WINDOWS_VM_COUNT} ]]; do
  vm_name="win-byoh-${vm_index}"
  vm_fqdn="${vm_name}.headless.${VM_NAMESPACE}.svc.cluster.local"
  secret_name="${vm_name}-unattend"

  echo "$(date -u --rfc-3339=seconds) - Creating VM ${vm_name} (${vm_index}/${CNV_WINDOWS_VM_COUNT})..."

  # Write cleanup marker
  touch "${SHARED_DIR}/${vm_name}_cnv_vm.txt"

  # Build the sysprep Secret YAML in a temp file so we can inject the SSH
  # public key without heredoc escaping issues.
  SECRET_FILE=$(mktemp)
  cat > "${SECRET_FILE}" << 'EOSECRET_TEMPLATE'
kind: Secret
apiVersion: v1
metadata:
  name: SECRET_NAME_PLACEHOLDER
  namespace: VM_NAMESPACE_PLACEHOLDER
stringData:
  Autounattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <!-- ignored on sysprepped images -->
  Unattend.xml: |
    <?xml version="1.0" encoding="utf-8"?>
    <unattend xmlns="urn:schemas-microsoft-com:unattend">
      <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <ExtendOSPartition>
            <Extend>true</Extend>
          </ExtendOSPartition>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
          <ComputerName>*</ComputerName>
          <TimeZone>UTC</TimeZone>
        </component>
      </settings>
      <settings pass="oobeSystem">
        <component xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
          <OOBE>
            <HideEULAPage>true</HideEULAPage>
            <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
            <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
            <NetworkLocation>Work</NetworkLocation>
            <SkipUserOOBE>true</SkipUserOOBE>
            <SkipMachineOOBE>true</SkipMachineOOBE>
            <ProtectYourPC>3</ProtectYourPC>
          </OOBE>
          <AutoLogon>
            <Password>
              <Value>W1nCM@ch1n3!</Value>
              <PlainText>true</PlainText>
            </Password>
            <Enabled>true</Enabled>
            <Username>Administrator</Username>
          </AutoLogon>
          <UserAccounts>
            <AdministratorPassword>
              <Value>W1nCM@ch1n3!</Value>
              <PlainText>true</PlainText>
            </AdministratorPassword>
          </UserAccounts>
          <FirstLogonCommands>
            <SynchronousCommand wcm:action="add">
              <Order>1</Order>
              <Description>Set Execution Policy</Description>
              <CommandLine>cmd.exe /c powershell -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Force"</CommandLine>
            </SynchronousCommand>
            <SynchronousCommand wcm:action="add">
              <Order>2</Order>
              <Description>Run BYOH setup script</Description>
              <CommandLine>cmd.exe /c powershell.exe -ExecutionPolicy Bypass -File D:\setup-byoh.ps1</CommandLine>
            </SynchronousCommand>
          </FirstLogonCommands>
        </component>
      </settings>
    </unattend>
  setup-byoh.ps1: |
    $ErrorActionPreference = 'Continue'
    $logDir = 'C:\var\log\byoh'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Start-Transcript -Path "$logDir\setup-byoh.log" -Append

    $vmName = (Get-CimInstance Win32_BIOS).SerialNumber
    Write-Host "VM name from SMBIOS serial: $vmName"

    Set-NetIPInterface -InterfaceAlias Ethernet -DadTransmits 0
    Set-DnsClientServerAddress -InterfaceAlias Ethernet -ServerAddresses 10.0.2.3,172.30.0.10

    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd

    $sshdConfigFilePath = "$env:ProgramData\ssh\sshd_config"
    $content = Get-Content -Path $sshdConfigFilePath
    $content = $content -replace '#PubkeyAuthentication yes','PubkeyAuthentication yes'
    $content = $content -replace '#PasswordAuthentication yes','PasswordAuthentication no'
    $content = $content -replace 'PasswordAuthentication yes','PasswordAuthentication no'
    $content | Set-Content -Path $sshdConfigFilePath

    $authorizedKeyConf = "$env:ProgramData\ssh\administrators_authorized_keys"
    New-Item -Force $authorizedKeyConf
    Set-Content -Path $authorizedKeyConf -Value "SSH_PUBLIC_KEY_PLACEHOLDER" -Encoding ASCII

    $acl = Get-Acl $authorizedKeyConf
    $acl.SetAccessRuleProtection($true, $false)
    $administratorsRule = New-Object System.Security.AccessControl.FileSystemAccessRule("Administrators","FullControl","Allow")
    $acl.SetAccessRule($administratorsRule)
    $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("SYSTEM","FullControl","Allow")
    $acl.SetAccessRule($systemRule)
    $acl | Set-Acl

    Set-NetFirewallRule -DisplayName "OpenSSH SSH Server (sshd)" -Profile Any

    Write-Host "Validating sshd_config..."
    $sshResult = & sshd.exe -t 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: sshd_config validation failed: $sshResult"
        Get-Content $sshdConfigFilePath
        exit 1
    }
    Write-Host "sshd_config validated successfully"

    Restart-Service sshd

    New-NetFirewallRule -DisplayName "ContainerLogsPort" -LocalPort 10250 -Enabled True -Direction Inbound -Protocol TCP -Action Allow -EdgeTraversalPolicy Allow
    New-NetFirewallRule -DisplayName "WindowsExporter" -LocalPort 9182 -Enabled True -Direction Inbound -Protocol TCP -Action Allow -EdgeTraversalPolicy Allow

    New-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\ -Name DisabledComponents -PropertyType DWord -Value 0xFF -Force

    New-Item -ItemType Directory -Path 'C:\k' -Force | Out-Null
    $vmName | Set-Content -Path 'C:\k\vm-name' -Force -NoNewline
    $startupScript = @'
    Start-Transcript -Path 'C:\var\log\byoh\add-pod-ip.log' -Append
    $vmName = Get-Content -Path 'C:\k\vm-name'
    $fqdn = "$vmName.headless.VM_NAMESPACE_PLACEHOLDER.svc.cluster.local"
    Write-Host "Resolving $fqdn"
    $attempt = 0
    do {
        $attempt++
        $result = Resolve-DnsName -Name $fqdn -Type A -ErrorAction SilentlyContinue
        if (-not $result) {
            Write-Host "Attempt $attempt failed, retrying in 5s..."
            Start-Sleep -Seconds 5
        }
    } while (-not $result -and $attempt -lt 24)
    if ($result) {
        $podIP = $result.IPAddress
        Write-Host "Resolved to $podIP"
        $existing = Get-NetIPAddress -InterfaceAlias Ethernet -IPAddress $podIP -ErrorAction SilentlyContinue
        if (-not $existing) {
            Write-Host "Adding $podIP as secondary address"
            netsh interface ipv4 add address "Ethernet" $podIP 255.255.255.0
        } else {
            Write-Host "$podIP already present"
        }
    } else {
        Write-Host "ERROR: could not resolve $fqdn after $attempt attempts"
    }
    $masq = Get-NetIPAddress -InterfaceAlias Ethernet -IPAddress 10.0.2.2 -ErrorAction SilentlyContinue
    if (-not $masq) {
        Write-Host "Masquerade IP 10.0.2.2 missing, re-adding"
        netsh interface ipv4 add address "Ethernet" 10.0.2.2 255.255.255.0 10.0.2.1
        Set-DnsClientServerAddress -InterfaceAlias Ethernet -ServerAddresses 10.0.2.3,172.30.0.10
    }
    Get-NetIPAddress -InterfaceAlias Ethernet -AddressFamily IPv4 | Format-Table IPAddress,AddressState
    Stop-Transcript
    '@
    $startupScript | Set-Content -Path 'C:\k\add-pod-ip.ps1' -Force
    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-ExecutionPolicy Bypass -File C:\k\add-pod-ip.ps1'
    $taskTrigger = New-ScheduledTaskTrigger -AtStartup
    $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries
    Register-ScheduledTask -TaskName 'AddPodIP' -Action $taskAction -Trigger $taskTrigger -Settings $taskSettings -User 'SYSTEM' -RunLevel Highest -Force

    Stop-Transcript

    Rename-Computer -NewName $vmName -Force -Restart
EOSECRET_TEMPLATE

  # Replace placeholders with actual values
  sed -i "s|SECRET_NAME_PLACEHOLDER|${secret_name}|g" "${SECRET_FILE}"
  sed -i "s|VM_NAMESPACE_PLACEHOLDER|${VM_NAMESPACE}|g" "${SECRET_FILE}"
  sed -i "s|SSH_PUBLIC_KEY_PLACEHOLDER|${SSH_PUBLIC_KEY}|g" "${SECRET_FILE}"

  oc apply -f "${SECRET_FILE}"
  rm -f "${SECRET_FILE}"

  # Create VirtualMachine
  cat <<EOVM | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: ${vm_name}
  namespace: ${VM_NAMESPACE}
spec:
  dataVolumeTemplates:
    - metadata:
        name: ${vm_name}-volume
      spec:
        source:
          pvc:
            name: ${DV_NAME}
            namespace: ${OS_IMAGES_NAMESPACE}
        storage:
          accessModes:
            - ReadWriteOnce
          volumeMode: Filesystem
          resources:
            requests:
              storage: 64Gi
  instancetype:
    name: u1.large
  preference:
    name: ${PREFERENCE_NAME}
  runStrategy: Always
  template:
    metadata:
      labels:
        network.kubevirt.io/headlessService: headless
    spec:
      subdomain: headless
      domain:
        firmware:
          serial: ${vm_name}
        devices:
          disks:
            - disk:
                bus: virtio
              name: rootdisk
            - cdrom:
                bus: sata
              name: sysprep
      volumes:
        - dataVolume:
            name: ${vm_name}-volume
          name: rootdisk
        - name: sysprep
          sysprep:
            secret:
              name: ${secret_name}
EOVM

  # Wait for KubeVirt to create the DataVolume from the VM's dataVolumeTemplates
  echo "$(date -u --rfc-3339=seconds) - Waiting for DataVolume ${vm_name}-volume to be created by KubeVirt..."
  dv_wait=0
  while [[ ${dv_wait} -lt 120 ]]; do
    if oc get datavolume "${vm_name}-volume" -n "${VM_NAMESPACE}" 2>/dev/null; then
      echo "$(date -u --rfc-3339=seconds) - DataVolume ${vm_name}-volume exists"
      break
    fi
    echo "$(date -u --rfc-3339=seconds) - DataVolume not yet created, waiting... (${dv_wait}s/120s)"
    sleep 10
    dv_wait=$((dv_wait + 10))
  done

  echo "$(date -u --rfc-3339=seconds) - Waiting for VM ${vm_name} DataVolume clone to complete..."
  oc wait datavolume "${vm_name}-volume" \
    -n "${VM_NAMESPACE}" \
    --for=jsonpath='{.status.phase}'=Succeeded \
    --timeout=30m || {
    echo "ERROR: DataVolume clone timed out for ${vm_name}-volume"
    oc get datavolume "${vm_name}-volume" -n "${VM_NAMESPACE}" -o yaml || true
    oc get events -n "${VM_NAMESPACE}" --sort-by='.lastTimestamp' | tail -20 || true
    exit 1
  }

  echo "$(date -u --rfc-3339=seconds) - Waiting for VMI ${vm_name} to reach Running phase..."
  oc wait vmi "${vm_name}" \
    -n "${VM_NAMESPACE}" \
    --for=jsonpath='{.status.phase}'=Running \
    --timeout=10m || {
    echo "ERROR: VMI ${vm_name} did not reach Running phase"
    oc get vmi "${vm_name}" -n "${VM_NAMESPACE}" -o yaml || true
    oc get events -n "${VM_NAMESPACE}" --sort-by='.lastTimestamp' | tail -20 || true
    exit 1
  }

  echo "$(date -u --rfc-3339=seconds) - VM ${vm_name} is running. Waiting for sysprep + reboot cycle to complete..."
  sleep 180

  # Get the pod IP from VMI status -- the CI step pod cannot resolve
  # cluster-internal DNS names (*.svc.cluster.local), so we SSH via IP.
  echo "$(date -u --rfc-3339=seconds) - Getting VM pod IP from VMI status..."
  vm_ip=""
  ip_attempts=0
  while [[ ${ip_attempts} -lt 20 ]]; do
    vm_ip=$(oc get vmi "${vm_name}" -n "${VM_NAMESPACE}" \
      -o jsonpath='{.status.interfaces[0].ipAddress}' 2>/dev/null || echo "")
    if [[ -n "${vm_ip}" ]]; then
      echo "$(date -u --rfc-3339=seconds) - VM pod IP: ${vm_ip}"
      break
    fi
    echo "$(date -u --rfc-3339=seconds) - IP not available yet, waiting... (${ip_attempts}/20)"
    sleep 15
    ((ip_attempts++)) || true
  done

  if [[ -z "${vm_ip}" ]]; then
    echo "ERROR: Could not get pod IP for VM ${vm_name}"
    oc get vmi "${vm_name}" -n "${VM_NAMESPACE}" -o yaml || true
    exit 1
  fi

  # Poll SSH readiness from INSIDE the target cluster.
  # The CI step pod runs on the build cluster and cannot reach the target
  # cluster's pod network directly. We use oc run to create a temporary
  # pod on the target cluster and SSH from there.
  echo "$(date -u --rfc-3339=seconds) - Waiting for SSH readiness on ${vm_ip} from inside the cluster..."

  # Create a Secret with the SSH private key on the target cluster
  oc create secret generic ssh-test-key \
    -n "${VM_NAMESPACE}" \
    --from-file=ssh-privatekey="${CLUSTER_PROFILE_DIR}/ssh-privatekey" 2>/dev/null || true

  ssh_attempts=0
  ssh_max=40
  ssh_ok=false
  while [[ ${ssh_attempts} -lt ${ssh_max} ]]; do
    ssh_result=$(oc run "ssh-test-${ssh_attempts}" --rm -i --restart=Never \
      -n "${VM_NAMESPACE}" \
      --image=registry.access.redhat.com/ubi9/ubi-minimal:latest \
      --overrides='{
        "spec": {
          "volumes": [{"name": "ssh-key", "secret": {"secretName": "ssh-test-key", "defaultMode": 384}}],
          "containers": [{
            "name": "ssh-test",
            "image": "registry.access.redhat.com/ubi9/ubi-minimal:latest",
            "command": ["bash", "-c", "microdnf install -y openssh-clients >/dev/null 2>&1 && ssh -i /ssh/ssh-privatekey -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes Administrator@'"${vm_ip}"' hostname 2>&1"],
            "volumeMounts": [{"name": "ssh-key", "mountPath": "/ssh", "readOnly": true}]
          }]
        }
      }' 2>/dev/null || echo "FAILED")

    if [[ "${ssh_result}" != "FAILED" && -n "${ssh_result}" && "${ssh_result}" != *"Permission denied"* && "${ssh_result}" != *"Connection refused"* && "${ssh_result}" != *"Connection timed out"* ]]; then
      echo "$(date -u --rfc-3339=seconds) - SSH succeeded (attempt ${ssh_attempts}/${ssh_max}): ${ssh_result}"
      ssh_ok=true
      break
    fi
    echo "$(date -u --rfc-3339=seconds) - SSH not ready (attempt ${ssh_attempts}/${ssh_max}): ${ssh_result}"
    sleep 30
    ((ssh_attempts++)) || true
  done

  # Clean up SSH key Secret
  oc delete secret ssh-test-key -n "${VM_NAMESPACE}" 2>/dev/null || true

  if [[ "${ssh_ok}" != "true" ]]; then
    echo "ERROR: SSH to ${vm_ip} (${vm_fqdn}) failed after ${ssh_max} attempts"
    echo "--- VMI status ---"
    oc get vmi "${vm_name}" -n "${VM_NAMESPACE}" -o yaml || true
    echo "--- Checking if sysprep ran (via guest agent) ---"
    oc get vmi "${vm_name}" -n "${VM_NAMESPACE}" \
      -o jsonpath='{.status.guestOSInfo}' 2>/dev/null | python3 -m json.tool 2>/dev/null || true
    exit 1
  fi

  # Write instance file using the DNS name (WMCO BYOH ConfigMap uses this
  # to connect from inside the cluster where DNS resolution works)
  instance_file="${SHARED_DIR}/${vm_fqdn}_windows_instance.txt"
  echo "username=Administrator" > "${instance_file}"
  echo "$(date -u --rfc-3339=seconds) - Created instance file: ${instance_file} (VM IP: ${vm_ip})"

  ((vm_index++)) || true
done

echo "=== Windows CNV Provision Complete: ${CNV_WINDOWS_VM_COUNT} VM(s) provisioned ==="
echo "Instance files in SHARED_DIR:"
ls -la "${SHARED_DIR}"/*_windows_instance.txt 2>/dev/null || echo "No instance files found"
