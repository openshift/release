# Instance name for the newly created Windows VM
variable winc_instance_name {
    type = string
}
# VCenter's resource pool where the new Winc BYOH instance will be created
# You can find it as a folder under the datacenter folder and it's the folder in which all
# the cluster machines are associated
# variable winc_resource_pool {
#     type = string
# }

variable winc_vsphere_template {
    type = string
    default = "windows-golden-images/windows-server-2022-template-qe"
}

# Number of BYOH worker instances
variable winc_number_workers {
    type = number
    default = 2
}
