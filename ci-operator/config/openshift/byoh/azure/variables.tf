# Resource group used 
variable winc_resource_group {
    type = string
}

# Resource prefix. Prefix used in all resources
variable winc_resource_prefix {
    type = string
}

# Hostname for one of the already existing cluster worker VM nodes
# You can get this info with: oc get nodes -l node-role.kubernetes.io/worker --no-headers
variable winc_machine_hostname {
    type = string
}

# Instance name assigned to the byoh instance
variable winc_instance_name {
    type = string
}

# Number of BYOH worker instances
variable winc_number_workers {
    type = number
    default = 2
}

# Instance type for the byoh instance
variable winc_instance_type {
    type = string
    default = "Standard_D2s_v3"
}

variable winc_worker_sku {
    type = string
}
