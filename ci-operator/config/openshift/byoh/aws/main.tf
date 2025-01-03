terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
  }
}

# USE Environment variables AWS_ACCESS_KEY and AWS_SECRET_ACCESS_KEY
# export AWS_ACCESS_KEY = "********"
# export AWS_SECRET_ACCESS_KEY = "*********"
provider "aws" {
  region     = var.winc_region
}

resource "aws_instance" "win_server" {
  count                     = "${var.winc_number_workers}"
  ami                       = var.winc_worker_ami
  instance_type             = var.winc_instance_type
  ebs_optimized             = false
  subnet_id                 = data.aws_instance.winc-machine-node.subnet_id
  security_groups           = data.aws_instance.winc-machine-node.vpc_security_group_ids
  iam_instance_profile      = data.aws_instance.winc-machine-node.iam_instance_profile
  user_data                 = data.template_file.windows-userdata[count.index].rendered

  root_block_device {
    volume_size = 120
    volume_type = "gp2"
  }

  tags = {
    Name = "${var.winc_instance_name}-${count.index}"
    "kubernetes.io/cluster/${var.winc_cluster_name}" = "owned"
  }
}

data "aws_instance" "winc-machine-node" {
    filter {
      name    = "private-dns-name"
      values  = [var.winc_machine_hostname]
    }
    filter {
      name   = "tag:kubernetes.io/cluster/${var.winc_cluster_name}"
      values = ["owned"]
    }
}

output "instance_ip" {
  value = "${aws_instance.win_server.*.private_ip}"
}

