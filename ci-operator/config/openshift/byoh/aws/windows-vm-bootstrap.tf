# Bootstrapping PowerShell Script
data "template_file" "windows-userdata" {
  count    = "${var.winc_number_workers}"
  template = <<EOF
<powershell>
# Rename Machine
Rename-Computer -NewName "${var.winc_instance_name}-${count.index}" -Force;# Install IIS
$authorizedKeyConf = "$env:ProgramData\ssh\administrators_authorized_keys"
$authorizedKeyFolder = Split-Path -Path $authorizedKeyConf
if (!(Test-Path $authorizedKeyFolder))
{
  New-Item -path $authorizedKeyFolder  -ItemType Directory
}
Write-Output "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDKyo2CxXHRP3Q5Ay0ZOlxCNSuH3xCSB68exLwE9b1fbvnzHQLfczM2oMySmEKmAN/l+mDSbrXVqx5Aa+Q76nmPK31ALbwCw94dd6A5IeM6t9PguWiodosXXccm7CgAh61+CIM6FkbrSw8mEFlUd/5LqQoi5xe3Y4ioYinXgDRIcN2aNaKr/BDGyMsnn4l9w/gOf+pMRQdqOa/cctKEt7SzMtnONNYKTf9hV2XQegVYNFgbmVKJvog3BR9jm8pAlE8mcGtn1QNsnNcXVqXRDKj/Sx1B7YfS631PVUX6Wpt2r2nYBwvUprmvh2Iqs/qBpG38kKe4afXRG9RNX65/ETiS/EdFta+q96Sbk/GOUPcn+NbNVwDFTKBdP0c88oPtp13vF78Ggdprx+uoUj6NAhb/bsnm4B1uKv71c++e+QqfFfjTcmtaCoZDRBHNT0FW+B/HLBhBQAV0qseSnZ69HYHgup0aKAbIwmsW5yqFewdU0CIPfgbPM06lo3/YkIunDf2IeEjzjz8LOtNmj+qiEsOU4xbMhbt9aeE4e6W6sC2FQrgqq2KFI27IvOeJSq6JAoXEIl+A5ZEhmjIKBrgucCZeMINB2c07354jGocq1A5d/oMc3YDoCc+HqDOCvugfxi8gQh1rKSrhZkOsvQTSzaLqpjLZEQ3IQU5oeRrKHPfDEQ== openshift-qe" | Out-File -FilePath $authorizedKeyConf -Encoding ascii
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
# SSH service startup type
Set-Service -Name ssh-agent -StartupType 'Automatic'
Set-Service -Name sshd -StartupType 'Automatic'
# start service
Start-Service ssh-agent
Start-Service sshd
# configure key based-authentication
$sshdConfigFilePath = "$env:ProgramData\ssh\sshd_config"
$pubKeyConf = (Get-Content -path $sshdConfigFilePath) -replace '#PubkeyAuthentication yes','PubkeyAuthentication yes'
$pubKeyConf | Set-Content -Path $sshdConfigFilePath
$passwordConf = (Get-Content -path $sshdConfigFilePath) -replace '#PasswordAuthentication yes','PasswordAuthentication yes'
$passwordConf | Set-Content -Path $sshdConfigFilePath
# create key file in configuration

$acl = Get-Acl $authorizedKeyConf
# disable inheritance
$acl.SetAccessRuleProtection($true, $false)
# set full control for Administrators
$administratorsRule = New-Object system.security.accesscontrol.filesystemaccessrule("Administrators","FullControl","Allow")
$acl.SetAccessRule($administratorsRule)
# set full control for SYSTEM
$systemRule = New-Object system.security.accesscontrol.filesystemaccessrule("SYSTEM","FullControl","Allow")
$acl.SetAccessRule($systemRule)
# apply file acl
$acl | Set-Acl
# restart service
Restart-Service sshd
# success
# Firewall Rules
New-NetFirewallRule -DisplayName "ContainerLogsPort" -LocalPort 10250 -Enabled True -Direction Inbound -Protocol TCP -Action Allow -EdgeTraversalPolicy Allow
# Install Docker
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
# configure repository policy
Set-PSRepository PSGallery -InstallationPolicy Trusted
# install module with provider
Install-Module -Name DockerMsftProvider -Repository PSGallery -Force
# install docker package
Install-Package -Name docker -ProviderName DockerMsftProvider -Force

# Restart
shutdown -r -t 10;
</powershell>
EOF
}