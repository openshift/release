# Instance name for the newly created Windows VM
variable winc_instance_name {
    type = string
}

# Template name for Windows VM in Nutanix
variable primary_windows_image {
    type = string
    default = "nutanix-windows-server-openshift.qcow2"
}

# Number of BYOH worker instances
variable winc_number_workers {
    type = number
    default = 2
}

# Required Nutanix provider variables
variable winc_cluster_name {
    type = string
}

variable subnet_uuid {
    type = string
}

# Nutanix Provider Authentication
variable nutanix_username {
    type = string
    description = "Username for Nutanix authentication"
}

variable nutanix_password {
    type = string
    description = "Password for Nutanix authentication"
}