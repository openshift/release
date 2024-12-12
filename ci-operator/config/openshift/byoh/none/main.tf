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
  ami                       = data.aws_ami.windows-ami.id
  instance_type             = var.winc_instance_type
  ebs_optimized             = false
  subnet_id                 = data.aws_instance.winc-machine-node.subnet_id
  security_groups           = data.aws_instance.winc-machine-node.vpc_security_group_ids
  iam_instance_profile      = data.aws_instance.winc-machine-node.iam_instance_profile
  user_data                 = data.template_file.windows-userdata[count.index].rendered

  root_block_device {
    volume_size = 120
    volume_type = "gp2"
    encrypted   = false
    delete_on_termination = true
  }

  tags = {
    Name = "${var.winc_instance_name}-${count.index}"
  }
}

# Get latest Windows Server AMI
data "aws_ami" "windows-ami" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Windows_Server-${var.winc_version}-English-Core-Base-*"]
  }
}

data "aws_instance" "winc-machine-node" {
    filter {
      name    = "private-dns-name"
      values  = [var.winc_machine_hostname]
    }
}

output "instance_ip" {
  value = "${aws_instance.win_server.*.private_ip}"
}

