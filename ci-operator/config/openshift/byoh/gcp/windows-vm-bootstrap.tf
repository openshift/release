# Bootstrapping PowerShell Script
data "template_file" "windows-userdata" {
  template = <<EOF
<powershell>
function Get-RandomPassword {
	Add-Type -AssemblyName 'System.Web'
	return [System.Web.Security.Membership]::GeneratePassword(16, 2)
}

# Check if the capi user exists, this will be the case on Azure, and will be used instead of Administrator
if((Get-LocalUser | Where-Object {$_.Name -eq "capi"}) -eq $null) {
	# The capi user doesn't exist, ensure the Administrator account is enabled if it exists
	# If neither users exist, an error will be written to the console, but the script will still continue
	$UserAccount = Get-LocalUser -Name "Administrator"
	if( ($UserAccount -ne $null) -and (!$UserAccount.Enabled) ) {
		$password = ConvertTo-SecureString Get-RandomPassword -asplaintext -force
		$UserAccount | Set-LocalUser -Password $password
		$UserAccount | Enable-LocalUser
	}
}

Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
$firewallRuleName = "ContainerLogsPort"
$containerLogsPort = "10250"
New-NetFirewallRule -DisplayName $firewallRuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $containerLogsPort -EdgeTraversalPolicy Allow
Set-Service -Name sshd -StartupType 'Automatic'
Start-Service sshd
$pubKeyConf = (Get-Content -path C:\ProgramData\ssh\sshd_config) -replace '#PubkeyAuthentication yes','PubkeyAuthentication yes'
$pubKeyConf | Set-Content -Path C:\ProgramData\ssh\sshd_config
$passwordConf = (Get-Content -path C:\ProgramData\ssh\sshd_config) -replace '#PasswordAuthentication yes','PasswordAuthentication yes'
$passwordConf | Set-Content -Path C:\ProgramData\ssh\sshd_config
$authorizedKeyFilePath = "$env:ProgramData\ssh\administrators_authorized_keys"
New-Item -Force $authorizedKeyFilePath
echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDKyo2CxXHRP3Q5Ay0ZOlxCNSuH3xCSB68exLwE9b1fbvnzHQLfczM2oMySmEKmAN/l+mDSbrXVqx5Aa+Q76nmPK31ALbwCw94dd6A5IeM6t9PguWiodosXXccm7CgAh61+CIM6FkbrSw8mEFlUd/5LqQoi5xe3Y4ioYinXgDRIcN2aNaKr/BDGyMsnn4l9w/gOf+pMRQdqOa/cctKEt7SzMtnONNYKTf9hV2XQegVYNFgbmVKJvog3BR9jm8pAlE8mcGtn1QNsnNcXVqXRDKj/Sx1B7YfS631PVUX6Wpt2r2nYBwvUprmvh2Iqs/qBpG38kKe4afXRG9RNX65/ETiS/EdFta+q96Sbk/GOUPcn+NbNVwDFTKBdP0c88oPtp13vF78Ggdprx+uoUj6NAhb/bsnm4B1uKv71c++e+QqfFfjTcmtaCoZDRBHNT0FW+B/HLBhBQAV0qseSnZ69HYHgup0aKAbIwmsW5yqFewdU0CIPfgbPM06lo3/YkIunDf2IeEjzjz8LOtNmj+qiEsOU4xbMhbt9aeE4e6W6sC2FQrgqq2KFI27IvOeJSq6JAoXEIl+A5ZEhmjIKBrgucCZeMINB2c07354jGocq1A5d/oMc3YDoCc+HqDOCvugfxi8gQh1rKSrhZkOsvQTSzaLqpjLZEQ3IQU5oeRrKHPfDEQ== openshift-qe"| Out-File $authorizedKeyFilePath -Encoding ascii
$acl = Get-Acl C:\ProgramData\ssh\administrators_authorized_keys
$acl.SetAccessRuleProtection($true, $false)
$administratorsRule = New-Object system.security.accesscontrol.filesystemaccessrule("Administrators","FullControl","Allow")
$systemRule = New-Object system.security.accesscontrol.filesystemaccessrule("SYSTEM","FullControl","Allow")
$acl.SetAccessRule($administratorsRule)
$acl.SetAccessRule($systemRule)
$acl | Set-Acl
Restart-Service sshd
</powershell>
<persist>true</persist>
EOF
}
