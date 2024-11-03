terraform {
  required_providers {
        azurerm = {
            source  = "hashicorp/azurerm"
            version = "> 3.0.0"
        }
  }
}

// USE Environment variables to login
# $ export ARM_CLIENT_ID="00000000-0000-0000-0000-000000000000"
# $ export ARM_CLIENT_SECRET="00000000-0000-0000-0000-000000000000"
# $ export ARM_SUBSCRIPTION_ID="00000000-0000-0000-0000-000000000000"
# $ export ARM_TENANT_ID="00000000-0000-0000-0000-000000000000"
provider "azurerm" {
    features {}
}

data "azurerm_resource_group" "winc_rg" {
  name = var.winc_resource_group
}

data "azurerm_subnet" "winc_subnet" {
  name = "${var.winc_resource_prefix}-worker-subnet"
  virtual_network_name = "${var.winc_resource_prefix}-vnet"
  resource_group_name = var.winc_resource_group
}

data "azurerm_platform_image" "windows-image" {
  location  = data.azurerm_resource_group.winc_rg.location
  sku       = "${var.winc_worker_sku}"
  offer     = "WindowsServer"
  publisher = "MicrosoftWindowsServer"
# Use utils/get_update_version.sh to get the most recent version
  version = var.winc_worker_sku == "2019-datacenter-smalldisk" ? "17763.4499.230606" : var.winc_worker_sku == "2022-datacenter-smalldisk" ? "20348.1787.230621" : null
}


data "azurerm_virtual_machine" "winc-machine-node" {
    name = var.winc_machine_hostname
    resource_group_name = var.winc_resource_group
}

resource "azurerm_network_interface" "winc-byoh-interface" {
  count               = "${var.winc_number_workers}"
  name                = "${var.winc_resource_prefix}-interface-${count.index}"
  location            = data.azurerm_resource_group.winc_rg.location
  resource_group_name = var.winc_resource_group

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.winc_subnet.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "win_server" {

  count     = "${var.winc_number_workers}"
  depends_on = [
    azurerm_network_interface.winc-byoh-interface
  ]
  name                = "${var.winc_instance_name}-${count.index}"
  resource_group_name = var.winc_resource_group
  location            = data.azurerm_resource_group.winc_rg.location
  size                = var.winc_instance_type
  admin_username      = "capi"
  admin_password      = "qwer1234!"
  network_interface_ids = [
    "${azurerm_network_interface.winc-byoh-interface[count.index].id}"
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = data.azurerm_platform_image.windows-image.publisher
    offer     = data.azurerm_platform_image.windows-image.offer
    sku       = data.azurerm_platform_image.windows-image.sku
    version   = data.azurerm_platform_image.windows-image.version
  }
}

resource "azurerm_virtual_machine_extension" "configure-byoh" {
  count     = "${var.winc_number_workers}"
  depends_on = [
    azurerm_windows_virtual_machine.win_server
  ]
  name                 = "configure-byoh"
  virtual_machine_id   = azurerm_windows_virtual_machine.win_server[count.index].id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  protected_settings = <<SETTINGS
  {
    "commandToExecute": "powershell -command \"[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('${base64encode(data.template_file.windows-userdata.rendered)}')) | Out-File -filepath install.ps1\" && powershell -ExecutionPolicy Unrestricted -File install.ps1"
  }
  SETTINGS
}

output "instance_ip" {
  value = "${azurerm_windows_virtual_machine.win_server.*.private_ip_address}"
}
