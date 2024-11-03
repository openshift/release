terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.40"
    }
  }
}

# USE Environment variables GOOGLE_CREDENTIALS pointing at the content of the service account json
# export GOOGLE_CREDENTIALS = "{*********}"
provider "google" {
  project    = var.winc_project 
  region     = var.winc_region 
  zone       = var.winc_zone
}

resource "google_compute_instance" "vm_instance" {
  count                     = "${var.winc_number_workers}"
  name                      = "${var.winc_instance_name}-${count.index}"
  machine_type              = var.winc_instance_type

  boot_disk {
    initialize_params {
      size = 128
      type = "pd-ssd"
      image = "projects/windows-cloud/global/images/family/${var.winc_win_version}"
    }
  }


  metadata = {
    sysprep-specialize-script-ps1 = data.template_file.windows-userdata.rendered
  } 
  

  network_interface {
    network = data.google_compute_instance.winc-machine-node.network_interface.0.network
    subnetwork = data.google_compute_instance.winc-machine-node.network_interface.0.subnetwork
  }

  service_account {
    email = data.google_compute_instance.winc-machine-node.service_account.0.email
    scopes = data.google_compute_instance.winc-machine-node.service_account.0.scopes
  }

  tags = data.google_compute_instance.winc-machine-node.tags
}


data "google_compute_instance" "winc-machine-node" {
  name    = var.winc_machine_hostname
}

output "instance_ip" {
  value = "${google_compute_instance.vm_instance.*.network_interface.0.network_ip}"
}

