terraform {
  required_providers {
    nutanix = {
      source  = "nutanix/nutanix"
      version = "~> 1.8.0"
    }
    template = {
      source = "hashicorp/template"
      version = "~> 2.2.0"
    }
  }
}

provider "nutanix" {
  username = var.nutanix_username
  password = var.nutanix_password
  endpoint = "prismcentral.lts-cluster.nutanix-dev.devcluster.openshift.com"
  insecure = true
  port     = 9440
}

# Get cluster info
data "nutanix_cluster" "cluster" {
  name = "Development-LTS"
}

# Get image info
data "nutanix_image" "windows" {
  image_name = var.primary_windows_image
}

resource "nutanix_virtual_machine" "win_server" {
  count                = var.winc_number_workers
  name                = "${var.winc_instance_name}-${count.index}"
  cluster_uuid        = data.nutanix_cluster.cluster.metadata.uuid
  
  num_vcpus_per_socket = 2
  num_sockets         = 1
  memory_size_mib     = 8192

  guest_customization_cloud_init_user_data = base64encode(data.template_file.windows-userdata[count.index].rendered)

  disk_list {
    data_source_reference = {
      kind = "image"
      uuid = data.nutanix_image.windows.metadata.uuid
    }
    disk_size_mib = 128000
  }

  nic_list {
    subnet_uuid = var.subnet_uuid
  }
}

output "instance_ip" {
  value = nutanix_virtual_machine.win_server[*].nic_list[0].ip_endpoint_list[0].ip
}